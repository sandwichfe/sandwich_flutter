package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
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
	// DurationSeconds 来自入库时 ffprobe 的结果，用于按时长展示进度。
	DurationSeconds int64
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
	// Reused 是"已有缓存直接复用、没有重新抽帧"的条目数，和异常跳过区分开。
	Reused      int
	Status      string
	CurrentItem string
	// CurrentItemProgress 是当前条目内 0~1 的抽帧进度，由 ffmpeg -progress 换算。
	CurrentItemProgress float64
	// CurrentItemDurationSeconds 是正在处理条目的时长，界面用它显示"当前视频多长"。
	CurrentItemDurationSeconds int64
	// TotalDurationSeconds 只统计时长有效的条目，避免探测失败的条目把分母拉偏。
	TotalDurationSeconds int64
	// DoneDurationSeconds 是"已处理时长"：成功条目的总时长 + 当前条目已解码的秒数，
	// 这样长片抽帧时数字也会持续增长，而不是等整条跑完才跳一次。
	DoneDurationSeconds int64
	// EstimatedFrames 按 时长/间隔 预估；GeneratedFrames 为已处理帧数，
	// 成功条目用实际写进 BIF 的帧数，处理中按已解码时长折算。
	EstimatedFrames int
	GeneratedFrames int
	Errors          []string
	StartedAt       string
	FinishedAt      string
}

// Progress 返回 0~1 的完成比例，供前端进度条直接使用。
// 运行中会把当前条目的解码进度折算进分子，否则条目少时进度条会长时间停在原地。
func (s ThumbnailJobSnapshot) Progress() float64 {
	if s.Total <= 0 {
		return 0
	}
	done := s.Completed + s.Failed + s.Skipped + s.Reused
	if done >= s.Total {
		return 1
	}
	fraction := 0.0
	if s.Status == ThumbnailJobRunning && s.CurrentItemProgress > 0 {
		fraction = s.CurrentItemProgress
		if fraction > 1 {
			fraction = 1
		}
	}
	return (float64(done) + fraction) / float64(s.Total)
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
// force 为 false 时已有同参数缓存（且不比片源旧）的条目直接复用，不会重新抽帧。
func (m *ThumbnailJobManager) Start(libraryID, libraryName string, targets []ThumbnailTarget, intervalMs, width int, force bool) (ThumbnailJobSnapshot, error) {
	if m.bif == nil {
		return ThumbnailJobSnapshot{}, errors.New("缩略图缓存未初始化")
	}
	// 启动前先确认 ffmpeg 可用，否则任务会逐条失败，界面上只看到"0 张"。
	if _, err := exec.LookPath(m.bif.FFmpegPath()); err != nil {
		return ThumbnailJobSnapshot{}, fmt.Errorf(
			"找不到 ffmpeg（当前配置：%q），请安装 ffmpeg 或用 EMBYX_FFMPEG / config.yaml 指定完整路径",
			m.bif.FFmpegPath(),
		)
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

	// 总时长与预估帧数在启动时一次算清，后续进度只做累加。
	intervalSeconds := int64(intervalMs / 1000)
	if intervalSeconds <= 0 {
		intervalSeconds = 1
	}
	var totalDuration int64
	estimatedFrames := 0
	for _, target := range targets {
		if target.DurationSeconds <= 0 {
			continue
		}
		totalDuration += target.DurationSeconds
		estimatedFrames += int((target.DurationSeconds + intervalSeconds - 1) / intervalSeconds)
	}

	ctx, cancel := context.WithCancel(context.Background())
	job := &thumbnailJob{cancel: cancel}
	job.snapshot = ThumbnailJobSnapshot{
		ID:                   newThumbnailJobID(),
		LibraryID:            libraryID,
		LibraryName:          libraryName,
		IntervalMs:           intervalMs,
		Width:                width,
		Total:                len(targets),
		Status:               ThumbnailJobRunning,
		TotalDurationSeconds: totalDuration,
		EstimatedFrames:      estimatedFrames,
		StartedAt:            time.Now().Format(time.RFC3339),
	}

	m.jobs[job.snapshot.ID] = job
	m.order = append(m.order, job.snapshot.ID)
	m.active = job
	m.trimLocked()
	snapshot := job.copy()
	m.mu.Unlock()

	go m.run(ctx, job, targets, force)
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

func (m *ThumbnailJobManager) run(ctx context.Context, job *thumbnailJob, targets []ThumbnailTarget, force bool) {
	defer job.cancel()

	initial := job.copy()
	intervalMs := uint32(initial.IntervalMs)
	width := initial.Width
	intervalSeconds := int64(intervalMs / 1000)
	if intervalSeconds <= 0 {
		intervalSeconds = 1
	}
	// 已完成条目的累计值先放在本地，快照里再叠加当前条目的实时进度。
	var doneBaseDuration int64
	var doneBaseFrames int

	startedAt := time.Now()
	log.Printf("[thumbnails] 任务 %s 开始: 库=%s 条目=%d 间隔=%dms 宽度=%d 总时长=%ds 预估帧=%d",
		initial.ID, initial.LibraryName, initial.Total, initial.IntervalMs, initial.Width,
		initial.TotalDurationSeconds, initial.EstimatedFrames)

	for index, target := range targets {
		if ctx.Err() != nil {
			job.update(func(s *ThumbnailJobSnapshot) {
				s.Status = ThumbnailJobCanceled
				s.CurrentItem = ""
				s.CurrentItemProgress = 0
				s.CurrentItemDurationSeconds = 0
				s.FinishedAt = time.Now().Format(time.RFC3339)
			})
			log.Printf("[thumbnails] 任务 %s 已取消: 成功=%d 失败=%d 跳过=%d",
				initial.ID, job.copy().Completed, job.copy().Failed, job.copy().Skipped)
			return
		}

		job.update(func(s *ThumbnailJobSnapshot) {
			s.CurrentItem = target.Name
			s.CurrentItemProgress = 0
			s.CurrentItemDurationSeconds = target.DurationSeconds
		})

		if target.Path == "" {
			job.update(func(s *ThumbnailJobSnapshot) { s.Skipped++ })
			log.Printf("[thumbnails] [%d/%d] 跳过 %s: 条目没有文件路径", index+1, len(targets), target.Name)
			continue
		}
		if _, err := os.Stat(target.Path); err != nil {
			job.update(func(s *ThumbnailJobSnapshot) {
				s.Skipped++
				appendThumbnailError(s, fmt.Sprintf("%s: 源文件不可读", target.Name))
			})
			log.Printf("[thumbnails] [%d/%d] 跳过 %s: 源文件不可读 (%v)", index+1, len(targets), target.Name, err)
			continue
		}

		itemStarted := time.Now()
		log.Printf("[thumbnails] [%d/%d] 开始 %s (时长 %ds) 路径=%s",
			index+1, len(targets), target.Name, target.DurationSeconds, target.Path)

		// ffmpeg 每 0.5 秒输出一次进度，这里按秒节流更新快照。
		lastPercent := -1
		lastElapsedSeconds := int64(-1)
		onProgress := func(elapsedMs int64) {
			if target.DurationSeconds <= 0 {
				return
			}
			percent := int(elapsedMs * 100 / (target.DurationSeconds * 1000))
			if percent > 99 {
				percent = 99
			}
			elapsedSeconds := elapsedMs / 1000
			if elapsedSeconds > target.DurationSeconds {
				elapsedSeconds = target.DurationSeconds
			}
			// 百分比和秒都没变就不写快照，避免长片每个 0.5 秒都抢一次锁。
			if percent <= lastPercent && elapsedSeconds <= lastElapsedSeconds {
				return
			}
			lastPercent = percent
			lastElapsedSeconds = elapsedSeconds
			// 当前条目的已解码时长折算成帧数，和"共约 N 张"同一口径。
			partialFrames := int(elapsedSeconds / intervalSeconds)
			job.update(func(s *ThumbnailJobSnapshot) {
				s.CurrentItemProgress = float64(percent) / 100
				s.DoneDurationSeconds = doneBaseDuration + elapsedSeconds
				s.GeneratedFrames = doneBaseFrames + partialFrames
			})
		}

		_, frames, reused, err := m.bif.Generate(ctx, target.ItemID, target.Path, BifOptions{
			IntervalMs: intervalMs,
			Width:      width,
			Force:      force,
			OnProgress: onProgress,
		})
		if err != nil {
			if ctx.Err() != nil {
				job.update(func(s *ThumbnailJobSnapshot) {
					s.Status = ThumbnailJobCanceled
					s.CurrentItem = ""
					s.CurrentItemProgress = 0
					s.CurrentItemDurationSeconds = 0
					s.FinishedAt = time.Now().Format(time.RFC3339)
				})
				log.Printf("[thumbnails] 任务 %s 已取消", initial.ID)
				return
			}
			job.update(func(s *ThumbnailJobSnapshot) {
				s.Failed++
				s.CurrentItemProgress = 0
				// 失败条目不推进"已处理"口径，把处理中临时加上的部分回退掉。
				s.DoneDurationSeconds = doneBaseDuration
				s.GeneratedFrames = doneBaseFrames
				appendThumbnailError(s, fmt.Sprintf("%s: %v", target.Name, err))
			})
			log.Printf("[thumbnails] [%d/%d] 失败 %s: %v", index+1, len(targets), target.Name, err)
			continue
		}

		// 只有成功条目才累加时长与帧数，失败和跳过不推进"已处理"口径。
		// 完成时用实际帧数收口，和抽帧过程中的折算值基本一致，不会出现跳变。
		doneBaseDuration += target.DurationSeconds
		doneBaseFrames += frames
		job.update(func(s *ThumbnailJobSnapshot) {
			if reused {
				s.Reused++
			} else {
				s.Completed++
			}
			s.CurrentItemProgress = 0
			s.DoneDurationSeconds = doneBaseDuration
			s.GeneratedFrames = doneBaseFrames
		})
		if reused {
			log.Printf("[thumbnails] [%d/%d] 复用 %s 已有缓存 帧=%d",
				index+1, len(targets), target.Name, frames)
			continue
		}
		log.Printf("[thumbnails] [%d/%d] 完成 %s 帧=%d 耗时=%s",
			index+1, len(targets), target.Name, frames, time.Since(itemStarted).Round(time.Millisecond))
	}

	final := job.copy()
	job.update(func(s *ThumbnailJobSnapshot) {
		s.Status = ThumbnailJobCompleted
		s.CurrentItem = ""
		s.CurrentItemProgress = 0
		s.CurrentItemDurationSeconds = 0
		s.FinishedAt = time.Now().Format(time.RFC3339)
	})
	log.Printf("[thumbnails] 任务 %s 完成: 成功=%d 复用=%d 失败=%d 跳过=%d 已生成帧=%d 耗时=%s",
		final.ID, final.Completed, final.Reused, final.Failed, final.Skipped, final.GeneratedFrames,
		time.Since(startedAt).Round(time.Second))
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
