package logging

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 跨零点后的第一次写入应切到新日期的文件，内容不能落到旧文件里。
func TestDailyWriterSwitchesDayOnWrite(t *testing.T) {
	dir := t.TempDir()
	writer, err := newDailyWriter(dir, "embyx", ".log", 7)
	if err != nil {
		t.Fatalf("创建 dailyWriter 失败: %v", err)
	}
	// 用闭包关闭：切日后 writer.file 会指向新文件，直接 defer writer.file.Close()
	// 拿到的是切日前的旧文件，新文件没人关，Windows 上 TempDir 清理会失败。
	defer func() { writer.file.Close() }()

	// 把内部日期改回昨天，模拟跨零点，避免测试依赖真实时间流逝。
	writer.day = time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	if _, err := writer.Write([]byte("next day\n")); err != nil {
		t.Fatalf("写入失败: %v", err)
	}

	path := filepath.Join(dir, "embyx-"+time.Now().Format("2006-01-02")+".log")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取当日日志失败: %v", err)
	}
	if string(data) != "next day\n" {
		t.Fatalf("日志内容不符: %q", data)
	}
}

// 启动时的清理应删掉超过保留天数的文件，同时不碰未超期文件和无关文件。
func TestCleanupRemovesExpiredFiles(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()

	expired := filepath.Join(dir, "embyx-"+now.AddDate(0, 0, -8).Format("2006-01-02")+".log")
	fresh := filepath.Join(dir, "embyx-"+now.AddDate(0, 0, -1).Format("2006-01-02")+".log")
	unrelated := filepath.Join(dir, "config.yaml")
	for _, path := range []string{expired, fresh, unrelated} {
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatalf("准备文件 %s 失败: %v", path, err)
		}
	}

	writer, err := newDailyWriter(dir, "embyx", ".log", 7)
	if err != nil {
		t.Fatalf("创建 dailyWriter 失败: %v", err)
	}
	defer func() { writer.file.Close() }()

	if _, err := os.Stat(expired); !os.IsNotExist(err) {
		t.Fatalf("超期文件应被删除: %s", expired)
	}
	for _, path := range []string{fresh, unrelated} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("文件不应被删除: %s (%v)", path, err)
		}
	}
}
