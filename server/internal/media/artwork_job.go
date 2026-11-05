package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"
)

// ErrArtworkJobRunning 表示已有批量生成任务在跑，前端需要先等待或取消。
var ErrArtworkJobRunning = errors.New("已有海报生成任务在运行")

// ErrArtworkJobNotFound 表示任务 ID 不存在（进程重启后历史任务会丢失）。
var ErrArtworkJobNotFound = errors.New("海报生成任务不存在")

// 任务状态取值，前端据此决定是否继续轮询。
const (
	ArtworkJobRunning   = "running"
	ArtworkJobCompleted = "completed"
	ArtworkJobCanceled  = "canceled"
)

// artworkJobHistory 只保留最近的任务，供设置页展示上一次结果。
const artworkJobHistory = 10

// artworkJobErrorLimit 限制错误明细条数，避免响应体被异常片源撑大。
const artworkJobErrorLimit = 10

// ArtworkTarget 是批量任务里的单个条目，Types 已在入队前算好实际缺哪些图。
type ArtworkTarget struct {
	ItemID       string
	Name         string
	Path         string
	RunTimeTicks int64
	// PositionTicks 为 0 时对该条目自动嗅探画面，否则按指定进度取帧。
	PositionTicks int64
	Types         []string
}

// ArtworkJobSnapshot 是任务状态的只读快照，可直接序列化给前端。
type ArtworkJobSnapshot struct {
	ID          string
	LibraryID   string
	LibraryName string
	Total       int
	Completed   int
	Failed      int
	// Generated 统计实际落盘的图片张数，一个条目可能同时生成海报和封面。
	Generated int
	// PositionRatio 是本次任务统一的取帧比例（0 表示自动嗅探），前端用于回显。
	PositionRatio float64
	Status        string
	CurrentItem   string
	Errors        []string
	StartedAt     string
	FinishedAt    string
}

// Progress 返回 0~1 的完成比例。
func (s ArtworkJobSnapshot) Progress() float64 {
	if s.Total <= 0 {
		return 0
	}
	done := s.Completed + s.Failed
	if done >= s.Total {
		return 1
	}
	return float64(done) / float64(s.Total)
}

type artworkJob struct {
	mu       sync.Mutex
	snapshot ArtworkJobSnapshot
	cancel   context.CancelFunc
}

func (j *artworkJob) update(fn func(*ArtworkJobSnapshot)) {
	j.mu.Lock()
	defer j.mu.Unlock()
	fn(&j.snapshot)
}

func (j *artworkJob) copy() ArtworkJobSnapshot {
	j.mu.Lock()
	defer j.mu.Unlock()
	snapshot := j.snapshot
	snapshot.Errors = append([]string(nil), j.snapshot.Errors...)
	return snapshot
}

// ArtworkJobManager 串行执行批量生成：同一时刻只跑一个库，
// 避免多个任务同时起 ffmpeg 把机器跑满。
type ArtworkJobManager struct {
	gen *ArtworkGenerator
	// onGenerated 在单个条目生成完成后回写 ImageTags，否则客户端不会请求图片。
	onGenerated func(itemID string, tags map[string]string)

	mu     sync.Mutex
	jobs   map[string]*artworkJob
	order  []string
	active *artworkJob
	// parentCtx 是任务的父 context，进程退出时取消，正在跑的 ffmpeg 一起结束。
	parentCtx context.Context
}

func NewArtworkJobManager(gen *ArtworkGenerator, onGenerated func(itemID string, tags map[string]string)) *ArtworkJobManager {
	return &ArtworkJobManager{
		gen:         gen,
		onGenerated: onGenerated,
		jobs:        make(map[string]*artworkJob),
	}
}

// SetParentContext 设置任务父 context，取消时正在运行的任务会被中断。
func (m *ArtworkJobManager) SetParentContext(ctx context.Context) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.parentCtx = ctx
}

// parentContextLocked 必须在持有 m.mu 时调用。
func (m *ArtworkJobManager) parentContextLocked() context.Context {
	if m.parentCtx != nil {
		return m.parentCtx
	}
	return context.Background()
}

// Start 启动批量任务，返回初始快照。任务在后台 goroutine 中执行。
// positionRatio 为 0 表示每条自动嗅探画面，否则为统一的取帧比例（0~1）。
func (m *ArtworkJobManager) Start(libraryID, libraryName string, targets []ArtworkTarget, positionRatio float64) (ArtworkJobSnapshot, error) {
	if m.gen == nil {
		return ArtworkJobSnapshot{}, errors.New("封面生成器未初始化")
	}
	if len(targets) == 0 {
		return ArtworkJobSnapshot{}, errors.New("没有需要生成海报或封面的条目")
	}

	m.mu.Lock()
	if m.active != nil && m.active.copy().Status == ArtworkJobRunning {
		m.mu.Unlock()
		return ArtworkJobSnapshot{}, ErrArtworkJobRunning
	}

	ctx, cancel := context.WithCancel(m.parentContextLocked())
	job := &artworkJob{cancel: cancel}
	job.snapshot = ArtworkJobSnapshot{
		ID:            newArtworkJobID(),
		LibraryID:     libraryID,
		LibraryName:   libraryName,
		Total:         len(targets),
		PositionRatio: positionRatio,
		Status:        ArtworkJobRunning,
		StartedAt:     time.Now().Format(time.RFC3339),
	}

	m.jobs[job.snapshot.ID] = job
	m.order = append(m.order, job.snapshot.ID)
	m.active = job
	m.trimLocked()
	snapshot := job.copy()
	m.mu.Unlock()

	go m.run(ctx, job, targets)
	return snapshot, nil
}

// Snapshot 读取任务当前状态。
func (m *ArtworkJobManager) Snapshot(jobID string) (ArtworkJobSnapshot, bool) {
	m.mu.Lock()
	job, ok := m.jobs[jobID]
	m.mu.Unlock()
	if !ok {
		return ArtworkJobSnapshot{}, false
	}
	return job.copy(), true
}

// Cancel 取消正在运行的任务；已完成的任务直接返回当前快照。
func (m *ArtworkJobManager) Cancel(jobID string) (ArtworkJobSnapshot, error) {
	m.mu.Lock()
	job, ok := m.jobs[jobID]
	m.mu.Unlock()
	if !ok {
		return ArtworkJobSnapshot{}, ErrArtworkJobNotFound
	}
	job.cancel()
	return job.copy(), nil
}

func (m *ArtworkJobManager) run(ctx context.Context, job *artworkJob, targets []ArtworkTarget) {
	defer job.cancel()

	initial := job.copy()
	startedAt := time.Now()
	mode := "自动嗅探"
	if initial.PositionRatio > 0 {
		mode = fmt.Sprintf("固定进度 %.0f%%", initial.PositionRatio*100)
	}
	log.Printf("[artwork] 任务 %s 开始: 库=%s 条目=%d 取帧=%s",
		initial.ID, initial.LibraryName, initial.Total, mode)

	for index, target := range targets {
		if ctx.Err() != nil {
			job.update(func(s *ArtworkJobSnapshot) {
				s.Status = ArtworkJobCanceled
				s.CurrentItem = ""
				s.FinishedAt = time.Now().Format(time.RFC3339)
			})
			log.Printf("[artwork] 任务 %s 已取消", initial.ID)
			return
		}

		job.update(func(s *ArtworkJobSnapshot) { s.CurrentItem = target.Name })
		itemStarted := time.Now()

		result, err := m.gen.Generate(ctx, target.ItemID, ArtworkOptions{
			SourcePath:    target.Path,
			RunTimeTicks:  target.RunTimeTicks,
			PositionTicks: target.PositionTicks,
			Types:         target.Types,
		})
		if err != nil {
			if ctx.Err() != nil {
				job.update(func(s *ArtworkJobSnapshot) {
					s.Status = ArtworkJobCanceled
					s.CurrentItem = ""
					s.FinishedAt = time.Now().Format(time.RFC3339)
				})
				log.Printf("[artwork] 任务 %s 已取消", initial.ID)
				return
			}
			job.update(func(s *ArtworkJobSnapshot) {
				s.Failed++
				s.CurrentItem = ""
				appendArtworkError(s, fmt.Sprintf("%s: %v", target.Name, err))
			})
			log.Printf("[artwork] [%d/%d] 失败 %s: %v", index+1, len(targets), target.Name, err)
			continue
		}

		if len(result.Tags) > 0 && m.onGenerated != nil {
			m.onGenerated(target.ItemID, result.Tags)
		}
		job.update(func(s *ArtworkJobSnapshot) {
			s.Completed++
			s.Generated += len(result.Tags)
			s.CurrentItem = ""
		})
		log.Printf("[artwork] [%d/%d] 完成 %s 类型=%d 耗时=%s",
			index+1, len(targets), target.Name, len(result.Tags),
			time.Since(itemStarted).Round(time.Millisecond))
	}

	final := job.copy()
	job.update(func(s *ArtworkJobSnapshot) {
		s.Status = ArtworkJobCompleted
		s.CurrentItem = ""
		s.FinishedAt = time.Now().Format(time.RFC3339)
	})
	log.Printf("[artwork] 任务 %s 完成: 成功=%d 失败=%d 图片=%d 耗时=%s",
		final.ID, final.Completed, final.Failed, final.Generated,
		time.Since(startedAt).Round(time.Second))
}

// trimLocked 丢弃超出保留数量的旧任务；调用方需持有 m.mu。
func (m *ArtworkJobManager) trimLocked() {
	for len(m.order) > artworkJobHistory {
		oldest := m.order[0]
		if job, ok := m.jobs[oldest]; ok && job.copy().Status == ArtworkJobRunning {
			return
		}
		delete(m.jobs, oldest)
		m.order = m.order[1:]
	}
}

func appendArtworkError(snapshot *ArtworkJobSnapshot, message string) {
	if len(snapshot.Errors) >= artworkJobErrorLimit {
		return
	}
	snapshot.Errors = append(snapshot.Errors, message)
}

func newArtworkJobID() string {
	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("artwork-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buffer)
}
