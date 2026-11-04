package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"
)

// ErrThumbnailJobRunning 表示已有预生成任务在跑，前端需要先等待或取消。
var ErrThumbnailJobRunning = errors.New("已有缩略图预生成任务在运行")

// ErrThumbnailJobNotFound 表示任务 ID 不存在（进程重启后历史任务会丢失）。
var ErrThumbnailJobNotFound = errors.New("缩略图预生成任务不存在")

// 任务状态取值，前端据此决定是否继续轮询进度。
const (
	ThumbnailJobRunning   = "running"
	ThumbnailJobCompleted = "completed"
	ThumbnailJobCanceled  = "canceled"
)

// thumbnailErrorLimit 限制错误明细条数，避免异常媒体库把响应体撑大。
const thumbnailErrorLimit = 20

// thumbnailJobHistory 只保留最近完成的任务，供设置页展示最近一次结果。
const thumbnailJobHistory = 20

// ThumbnailTarget 是预生成任务里的单个条目。
type ThumbnailTarget struct {
	ItemID string
	Name   string
	Path   string
}

// ThumbnailJobSnapshot 是任务状态的只读快照，可直接序列化给前端。
type ThumbnailJobSnapshot struct {
	ID          string
	LibraryID   string
	LibraryName string
	IntervalMs  int
	Width       int
	Total       int
	Completed   int
	Failed      int
	Skipped     int
	Status      string
	CurrentItem string
	Errors      []string
	StartedAt   string
	FinishedAt  string
}

// Progress 返回 0~1 的完成比例，供前端进度条直接使用。
func (s ThumbnailJobSnapshot) Progress() float64 {
	if s.Total <= 0 {
		return 0
	}
	done := s.Completed + s.Failed + s.Skipped
	if done >= s.Total {
		return 1
	}
	return float64(done) / float64(s.Total)
}

type thumbnailJob struct {
	mu       sync.Mutex
	snapshot ThumbnailJobSnapshot
	cancel   context.CancelFunc
}

func (j *thumbnailJob) update(fn func(*ThumbnailJobSnapshot)) {
	j.mu.Lock()
	defer j.mu.Unlock()
	fn(&j.snapshot)
}

func (j *thumbnailJob) copy() ThumbnailJobSnapshot {
	j.mu.Lock()
	defer j.mu.Unlock()
	snapshot := j.snapshot
	snapshot.Errors = append([]string(nil), j.snapshot.Errors...)
	return snapshot
}

// ThumbnailJobManager 串行执行预生成任务：同一时刻只跑一个库，
// 避免多个任务同时调用 ffmpeg 拖慢播放与扫描。
type ThumbnailJobManager struct {
	bif *BifCache

	mu     sync.Mutex
	jobs   map[string]*thumbnailJob
	order  []string
	active *thumbnailJob
}

func NewThumbnailJobManager(bif *BifCache) *ThumbnailJobManager {
	return &ThumbnailJobManager{bif: bif, jobs: make(map[string]*thumbnailJob)}
}

// Start 启动一个预生成任务，返回初始快照。任务在后台 goroutine 中执行。
func (m *ThumbnailJobManager) Start(libraryID, libraryName string, targets []ThumbnailTarget, intervalMs, width int) (ThumbnailJobSnapshot, error) {
	if m.bif == nil {
		return ThumbnailJobSnapshot{}, errors.New("缩略图缓存未初始化")
	}
	if intervalMs <= 0 {
		intervalMs = 10000
	}
	if width <= 0 {
		width = 320
	}

	m.mu.Lock()
	if m.active != nil && m.active.copy().Status == ThumbnailJobRunning {
		m.mu.Unlock()
		return ThumbnailJobSnapshot{}, ErrThumbnailJobRunning
	}

	ctx, cancel := context.WithCancel(context.Background())
	job := &thumbnailJob{cancel: cancel}
	job.snapshot = ThumbnailJobSnapshot{
		ID:          newThumbnailJobID(),
		LibraryID:   libraryID,
		LibraryName: libraryName,
		IntervalMs:  intervalMs,
		Width:       width,
		Total:       len(targets),
		Status:      ThumbnailJobRunning,
		StartedAt:   time.Now().Format(time.RFC3339),
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
func (m *ThumbnailJobManager) Snapshot(jobID string) (ThumbnailJobSnapshot, bool) {
	m.mu.Lock()
	job, ok := m.jobs[jobID]
	m.mu.Unlock()
	if !ok {
		return ThumbnailJobSnapshot{}, false
	}
	return job.copy(), true
}

// Active 返回正在运行的任务，没有则返回 false。
func (m *ThumbnailJobManager) Active() (ThumbnailJobSnapshot, bool) {
	m.mu.Lock()
	job := m.active
	m.mu.Unlock()
	if job == nil {
		return ThumbnailJobSnapshot{}, false
	}
	snapshot := job.copy()
	if snapshot.Status != ThumbnailJobRunning {
		return ThumbnailJobSnapshot{}, false
	}
	return snapshot, true
}

// List 按时间倒序返回最近的任务，最新的排在最前。
func (m *ThumbnailJobManager) List() []ThumbnailJobSnapshot {
	m.mu.Lock()
	ids := append([]string(nil), m.order...)
	jobs := make([]*thumbnailJob, 0, len(ids))
	for _, id := range ids {
		if job, ok := m.jobs[id]; ok {
			jobs = append(jobs, job)
		}
	}
	m.mu.Unlock()

	snapshots := make([]ThumbnailJobSnapshot, 0, len(jobs))
	for index := len(jobs) - 1; index >= 0; index-- {
		snapshots = append(snapshots, jobs[index].copy())
	}
	return snapshots
}

// Cancel 取消正在运行的任务；已完成的任务直接返回当前快照。
func (m *ThumbnailJobManager) Cancel(jobID string) (ThumbnailJobSnapshot, error) {
	m.mu.Lock()
	job, ok := m.jobs[jobID]
	m.mu.Unlock()
	if !ok {
		return ThumbnailJobSnapshot{}, ErrThumbnailJobNotFound
	}
	job.cancel()
	return job.copy(), nil
}

func (m *ThumbnailJobManager) run(ctx context.Context, job *thumbnailJob, targets []ThumbnailTarget) {
	defer job.cancel()

	initial := job.copy()
	intervalMs := uint32(initial.IntervalMs)
	width := initial.Width

	for _, target := range targets {
		if ctx.Err() != nil {
			job.update(func(s *ThumbnailJobSnapshot) {
				s.Status = ThumbnailJobCanceled
				s.CurrentItem = ""
				s.FinishedAt = time.Now().Format(time.RFC3339)
			})
			return
		}

		job.update(func(s *ThumbnailJobSnapshot) { s.CurrentItem = target.Name })

		if target.Path == "" {
			job.update(func(s *ThumbnailJobSnapshot) { s.Skipped++ })
			continue
		}
		if _, err := os.Stat(target.Path); err != nil {
			job.update(func(s *ThumbnailJobSnapshot) {
				s.Skipped++
				appendThumbnailError(s, fmt.Sprintf("%s: 源文件不可读", target.Name))
			})
			continue
		}

		if _, err := m.bif.Generate(ctx, target.ItemID, target.Path, intervalMs, width, true); err != nil {
			if ctx.Err() != nil {
				job.update(func(s *ThumbnailJobSnapshot) {
					s.Status = ThumbnailJobCanceled
					s.CurrentItem = ""
					s.FinishedAt = time.Now().Format(time.RFC3339)
				})
				return
			}
			job.update(func(s *ThumbnailJobSnapshot) {
				s.Failed++
				appendThumbnailError(s, fmt.Sprintf("%s: %v", target.Name, err))
			})
			continue
		}
		job.update(func(s *ThumbnailJobSnapshot) { s.Completed++ })
	}

	job.update(func(s *ThumbnailJobSnapshot) {
		s.Status = ThumbnailJobCompleted
		s.CurrentItem = ""
		s.FinishedAt = time.Now().Format(time.RFC3339)
	})
}

// trimLocked 丢弃超出保留数量的旧任务；调用方需持有 m.mu。
func (m *ThumbnailJobManager) trimLocked() {
	for len(m.order) > thumbnailJobHistory {
		oldest := m.order[0]
		if job, ok := m.jobs[oldest]; ok && job.copy().Status == ThumbnailJobRunning {
			return
		}
		delete(m.jobs, oldest)
		m.order = m.order[1:]
	}
}

func appendThumbnailError(snapshot *ThumbnailJobSnapshot, message string) {
	if len(snapshot.Errors) >= thumbnailErrorLimit {
		return
	}
	snapshot.Errors = append(snapshot.Errors, message)
}

func newThumbnailJobID() string {
	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("job-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buffer)
}
