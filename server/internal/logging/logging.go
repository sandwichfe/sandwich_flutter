// Package logging 负责进程级日志的初始化：
// 标准库 log 的输出同时进控制台，以及 exe 同目录下按日期切分的日志文件。
package logging

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	// filePrefix 是日志文件名前缀，与日志行前缀 [embyx] 保持一致。
	filePrefix = "embyx"
	// fileExt 是日志文件扩展名，文件名形如 embyx-2026-11-11.log。
	fileExt = ".log"
	// retentionDays 是日志保留天数：换日时清理超过该天数的旧文件。
	// 按天切分后单文件不再无界增长，历史文件靠这里回收。
	retentionDays = 7
)

// Setup 把标准库 log 改成「控制台 + 按日期切分的文件」双写。
// 双击运行时控制台会随进程退出关闭，日志文件是排查启动失败的唯一线索；
// 取不到程序路径或文件打不开时保持默认的 stderr 输出，不能因此影响启动。
func Setup() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[" + filePrefix + "] ")

	executable, err := os.Executable()
	if err != nil {
		return
	}
	writer, err := newDailyWriter(filepath.Dir(executable), filePrefix, fileExt, retentionDays)
	if err != nil {
		return
	}
	log.SetOutput(io.MultiWriter(os.Stderr, writer))
}

// dailyWriter 按日期切分日志文件，文件名形如 embyx-2026-11-11.log。
// 切换在写入时判断（跨零点后的第一条日志触发换文件），不需要额外的定时协程；
// 相比按大小轮转，"某天出现了什么"可以直接按文件名定位。
type dailyWriter struct {
	mu        sync.Mutex
	dir       string
	prefix    string
	ext       string
	retention int
	day       string // 当前文件对应的日期，格式 2006-01-02
	file      *os.File
}

func newDailyWriter(dir, prefix, ext string, retention int) (*dailyWriter, error) {
	writer := &dailyWriter{dir: dir, prefix: prefix, ext: ext, retention: retention}
	if err := writer.rotate(time.Now()); err != nil {
		return nil, err
	}
	// 启动时先回收一轮：进程可能停了很久，旧文件得靠这次启动清掉。
	writer.cleanup(time.Now())
	return writer, nil
}

// rotate 打开 now 所在日期的文件并关闭旧文件。新文件打不开时保留旧文件继续写，
// 日志丢失比进程崩溃更容易接受。
func (w *dailyWriter) rotate(now time.Time) error {
	day := now.Format("2006-01-02")
	path := filepath.Join(w.dir, w.prefix+"-"+day+w.ext)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	if w.file != nil {
		_ = w.file.Close()
	}
	w.file = file
	w.day = day
	return nil
}

func (w *dailyWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	now := time.Now()
	if w.file == nil || now.Format("2006-01-02") != w.day {
		if err := w.rotate(now); err == nil {
			w.cleanup(now)
		}
	}
	if w.file == nil {
		return 0, os.ErrClosed
	}
	return w.file.Write(p)
}

// cleanup 删除超过保留天数的旧日志。文件名不符合 prefix-日期.ext 的一律跳过，
// 避免误删同目录下的其他文件。
func (w *dailyWriter) cleanup(now time.Time) {
	entries, err := os.ReadDir(w.dir)
	if err != nil {
		return
	}
	cutoff := now.AddDate(0, 0, -w.retention)
	prefix := w.prefix + "-"
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, w.ext) {
			continue
		}
		day, err := time.Parse("2006-01-02", strings.TrimSuffix(strings.TrimPrefix(name, prefix), w.ext))
		if err != nil || !day.Before(cutoff) {
			continue
		}
		_ = os.Remove(filepath.Join(w.dir, name))
	}
}
