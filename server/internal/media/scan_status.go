package media

import (
	"sync"
	"time"
)

// ScanFailure 记录扫描中失败的文件与原因，由 /Library/ScanStatus 输出给前端。
type ScanFailure struct {
	Path   string
	Reason string
}

// ScanProgress 是一次扫描的实时快照。
// 多库连续扫描时 Scanned/Total 是整轮累计值，LibraryName/CurrentPath 指向当前正在处理的库与文件。
type ScanProgress struct {
	Running     bool
	LibraryID   string
	LibraryName string
	Scanned     int
	Total       int
	CurrentPath string
	Failures    []ScanFailure
	StartedAt   time.Time
	// FinishedAt 为零值时表示本轮还没结束。
	FinishedAt time.Time
}

// maxScanFailures 限制失败列表长度：目录权限异常时可能一次刷出几千条，
// 内存占用和响应体都不该跟着涨。
const maxScanFailures = 200

// scanProgress 用互斥锁保护扫描状态：worker 并发写计数，HTTP 处理器随时读快照。
type scanProgress struct {
	mu    sync.Mutex
	state ScanProgress
}

func (p *scanProgress) begin() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.state = ScanProgress{Running: true, StartedAt: time.Now()}
}

func (p *scanProgress) finish() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.state.Running = false
	p.state.FinishedAt = time.Now()
	p.state.CurrentPath = ""
}

func (p *scanProgress) setLibrary(id, name string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.state.LibraryID = id
	p.state.LibraryName = name
}

func (p *scanProgress) addFiles(count int) {
	if count <= 0 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.state.Total += count
}

func (p *scanProgress) markScanned(path string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.state.Scanned++
	p.state.CurrentPath = path
}

func (p *scanProgress) addFailure(path string, err error) {
	if err == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.state.Failures) >= maxScanFailures {
		return
	}
	p.state.Failures = append(p.state.Failures, ScanFailure{Path: path, Reason: err.Error()})
}

// Progress 返回扫描状态快照；从未扫描过时 Running 为 false 且 StartedAt 为零值。
func (s *Scanner) Progress() ScanProgress {
	return s.progress.snapshot()
}

func (p *scanProgress) snapshot() ScanProgress {
	p.mu.Lock()
	defer p.mu.Unlock()
	result := p.state
	// 复制一份失败列表，避免调用方在序列化时和写入方抢同一片内存。
	result.Failures = append([]ScanFailure(nil), p.state.Failures...)
	return result
}
