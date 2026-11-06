package metadata

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"runtime/debug"
	"sync"
	"time"

	"embyx/internal/media"
	"embyx/internal/store"
)

var (
	// ErrPersonScrapeRunning 表示已有刮削任务在跑，前端需要等待或取消。
	ErrPersonScrapeRunning = errors.New("已有演员刮削任务在运行")
	// ErrPersonScrapeNotFound 表示任务 ID 不存在（进程重启后历史任务会丢失）。
	ErrPersonScrapeNotFound = errors.New("演员刮削任务不存在")
)

const (
	PersonScrapeRunning   = "running"
	PersonScrapeCompleted = "completed"
	PersonScrapeCanceled  = "canceled"

	// personScrapeJobHistory 只保留最近的任务，供设置页展示上一次结果。
	personScrapeJobHistory = 10
	// personScrapeErrorLimit 限制错误明细条数，避免响应体被异常数据撑大。
	personScrapeErrorLimit = 10
)

// PersonScrapeJobSnapshot 是任务状态的只读快照，可直接序列化给前端。
type PersonScrapeJobSnapshot struct {
	ID string
	// Mode 取值 all / missing / single，前端用于回显本次范围。
	Mode string
	// Force 表示是否允许覆盖已有字段（手动锁定的字段依然不动）。
	Force     bool
	Total     int
	Completed int
	Failed    int
	// Skipped 统计重名待确认与没找到的人数，它们没有写入任何资料。
	Skipped int
	// Updated 统计真正写入了新资料的人数。
	Updated int
	// Images 统计下载并落盘的图片张数（头像 + 写真）。
	Images      int
	Status      string
	CurrentItem string
	Errors      []string
	StartedAt   string
	FinishedAt  string
}

// Progress 返回 0~1 的完成比例。
func (s PersonScrapeJobSnapshot) Progress() float64 {
	if s.Total <= 0 {
		return 0
	}
	done := s.Completed + s.Failed + s.Skipped
	if done >= s.Total {
		return 1
	}
	return float64(done) / float64(s.Total)
}

type personScrapeJob struct {
	mu       sync.Mutex
	snapshot PersonScrapeJobSnapshot
	cancel   context.CancelFunc
}

func (j *personScrapeJob) update(fn func(*PersonScrapeJobSnapshot)) {
	j.mu.Lock()
	defer j.mu.Unlock()
	fn(&j.snapshot)
}

func (j *personScrapeJob) copy() PersonScrapeJobSnapshot {
	j.mu.Lock()
	defer j.mu.Unlock()
	snapshot := j.snapshot
	snapshot.Errors = append([]string(nil), j.snapshot.Errors...)
	return snapshot
}

// PersonScrapeJobManager 串行执行演员刮削：同一时刻只跑一个任务，
// 既避免把 TMDB 限流打满，也让进度条与取消语义保持简单。
type PersonScrapeJobManager struct {
	scraper *PersonScraper

	mu        sync.Mutex
	jobs      map[string]*personScrapeJob
	order     []string
	active    *personScrapeJob
	parentCtx context.Context
}

func NewPersonScrapeJobManager(scraper *PersonScraper) *PersonScrapeJobManager {
	return &PersonScrapeJobManager{
		scraper: scraper,
		jobs:    make(map[string]*personScrapeJob),
	}
}

// SetParentContext 设置任务父 context，进程退出时取消正在运行的刮削。
func (m *PersonScrapeJobManager) SetParentContext(ctx context.Context) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.parentCtx = ctx
}

func (m *PersonScrapeJobManager) parentContextLocked() context.Context {
	if m.parentCtx != nil {
		return m.parentCtx
	}
	return context.Background()
}

// Start 启动刮削任务，返回初始快照；任务在后台 goroutine 中执行。
func (m *PersonScrapeJobManager) Start(targets []store.PersonScrapeTarget, force bool, mode string) (PersonScrapeJobSnapshot, error) {
	if m.scraper == nil {
		return PersonScrapeJobSnapshot{}, errors.New("演员刮削器未初始化")
	}
	if len(targets) == 0 {
		return PersonScrapeJobSnapshot{}, errors.New("没有需要刮削的演员")
	}

	m.mu.Lock()
	if m.active != nil && m.active.copy().Status == PersonScrapeRunning {
		m.mu.Unlock()
		return PersonScrapeJobSnapshot{}, ErrPersonScrapeRunning
	}

	ctx, cancel := context.WithCancel(m.parentContextLocked())
	job := &personScrapeJob{cancel: cancel}
	job.snapshot = PersonScrapeJobSnapshot{
		ID:        newPersonScrapeJobID(),
		Mode:      mode,
		Force:     force,
		Total:     len(targets),
		Status:    PersonScrapeRunning,
		StartedAt: time.Now().Format(time.RFC3339),
	}

	m.jobs[job.snapshot.ID] = job
	m.order = append(m.order, job.snapshot.ID)
	m.active = job
	m.trimLocked()
	snapshot := job.copy()
	m.mu.Unlock()

	media.RunSafe("演员刮削任务", func() { m.run(ctx, job, targets) })
	return snapshot, nil
}

// Snapshot 读取任务当前状态。
func (m *PersonScrapeJobManager) Snapshot(jobID string) (PersonScrapeJobSnapshot, bool) {
	m.mu.Lock()
	job, ok := m.jobs[jobID]
	m.mu.Unlock()
	if !ok {
		return PersonScrapeJobSnapshot{}, false
	}
	return job.copy(), true
}

// List 返回最近的任务（新在前），设置页打开时用它恢复进度。
func (m *PersonScrapeJobManager) List() []PersonScrapeJobSnapshot {
	m.mu.Lock()
	order := append([]string(nil), m.order...)
	jobs := make(map[string]*personScrapeJob, len(m.jobs))
	for id, job := range m.jobs {
		jobs[id] = job
	}
	m.mu.Unlock()

	snapshots := make([]PersonScrapeJobSnapshot, 0, len(order))
	for index := len(order) - 1; index >= 0; index-- {
		if job, ok := jobs[order[index]]; ok {
			snapshots = append(snapshots, job.copy())
		}
	}
	return snapshots
}

// Cancel 取消正在运行的任务；已完成的任务直接返回当前快照。
func (m *PersonScrapeJobManager) Cancel(jobID string) (PersonScrapeJobSnapshot, error) {
	m.mu.Lock()
	job, ok := m.jobs[jobID]
	m.mu.Unlock()
	if !ok {
		return PersonScrapeJobSnapshot{}, ErrPersonScrapeNotFound
	}
	job.cancel()
	return job.copy(), nil
}

func (m *PersonScrapeJobManager) run(ctx context.Context, job *personScrapeJob, targets []store.PersonScrapeTarget) {
	defer job.cancel()
	// panic 时收尾成"已取消"，避免 active 卡在 running 导致再也起不了新任务。
	defer func() {
		if recovered := recover(); recovered != nil {
			log.Printf("[person-scrape] 任务 %s panic: %v\n%s", job.copy().ID, recovered, debug.Stack())
			job.update(func(s *PersonScrapeJobSnapshot) {
				s.Status = PersonScrapeCanceled
				s.CurrentItem = ""
				s.FinishedAt = time.Now().Format(time.RFC3339)
				appendPersonScrapeError(s, fmt.Sprintf("内部错误: %v", recovered))
			})
		}
	}()

	initial := job.copy()
	startedAt := time.Now()
	log.Printf("[person-scrape] 任务 %s 开始: 演员=%d 范围=%s 覆盖=%v",
		initial.ID, initial.Total, initial.Mode, initial.Force)

	for index, target := range targets {
		if ctx.Err() != nil {
			job.update(func(s *PersonScrapeJobSnapshot) {
				s.Status = PersonScrapeCanceled
				s.CurrentItem = ""
				s.FinishedAt = time.Now().Format(time.RFC3339)
			})
			log.Printf("[person-scrape] 任务 %s 已取消", initial.ID)
			return
		}

		job.update(func(s *PersonScrapeJobSnapshot) { s.CurrentItem = target.Name })
		outcome, err := m.scraper.Scrape(ctx, target, initial.Force)
		if err != nil {
			if ctx.Err() != nil {
				job.update(func(s *PersonScrapeJobSnapshot) {
					s.Status = PersonScrapeCanceled
					s.CurrentItem = ""
					s.FinishedAt = time.Now().Format(time.RFC3339)
				})
				log.Printf("[person-scrape] 任务 %s 已取消", initial.ID)
				return
			}
			job.update(func(s *PersonScrapeJobSnapshot) {
				s.Failed++
				s.CurrentItem = ""
				appendPersonScrapeError(s, fmt.Sprintf("%s: %v", target.Name, err))
			})
			log.Printf("[person-scrape] [%d/%d] 失败 %s: %v", index+1, len(targets), target.Name, err)
			continue
		}

		job.update(func(s *PersonScrapeJobSnapshot) {
			s.CurrentItem = ""
			if outcome.State == store.PersonMatchMatched {
				s.Completed++
				if outcome.Updated {
					s.Updated++
				}
				s.Images += outcome.Images
				return
			}
			s.Skipped++
		})
		log.Printf("[person-scrape] [%d/%d] %s 状态=%s 更新=%v 图片=%d",
			index+1, len(targets), target.Name, outcome.State, outcome.Updated, outcome.Images)
	}

	final := job.copy()
	job.update(func(s *PersonScrapeJobSnapshot) {
		s.Status = PersonScrapeCompleted
		s.CurrentItem = ""
		s.FinishedAt = time.Now().Format(time.RFC3339)
	})
	log.Printf("[person-scrape] 任务 %s 完成: 成功=%d 跳过=%d 失败=%d 更新=%d 图片=%d 耗时=%s",
		final.ID, final.Completed, final.Skipped, final.Failed, final.Updated, final.Images,
		time.Since(startedAt).Round(time.Second))
}

// trimLocked 丢弃超出保留数量的旧任务；调用方需持有 m.mu。
func (m *PersonScrapeJobManager) trimLocked() {
	for len(m.order) > personScrapeJobHistory {
		oldest := m.order[0]
		if job, ok := m.jobs[oldest]; ok && job.copy().Status == PersonScrapeRunning {
			return
		}
		delete(m.jobs, oldest)
		m.order = m.order[1:]
	}
}

func appendPersonScrapeError(snapshot *PersonScrapeJobSnapshot, message string) {
	if len(snapshot.Errors) >= personScrapeErrorLimit {
		return
	}
	snapshot.Errors = append(snapshot.Errors, message)
}

func newPersonScrapeJobID() string {
	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("person-scrape-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buffer)
}
