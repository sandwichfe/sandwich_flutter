package store

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestOpenAppliesPerConnectionPragmas(t *testing.T) {
	// 目录名带中文与空格，顺带验证 DSN 拼接不会破坏路径。
	dir := filepath.Join(t.TempDir(), "数据 目录")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	st, err := Open(filepath.Join(dir, "embyx.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	var busyTimeout int
	if err := st.DB().QueryRow(`PRAGMA busy_timeout`).Scan(&busyTimeout); err != nil {
		t.Fatalf("读取 busy_timeout 失败: %v", err)
	}
	if busyTimeout != 5000 {
		t.Errorf("busy_timeout = %d, 期望 5000（DSN 参数未生效）", busyTimeout)
	}

	// synchronous: 0=OFF 1=NORMAL 2=FULL
	var synchronous int
	if err := st.DB().QueryRow(`PRAGMA synchronous`).Scan(&synchronous); err != nil {
		t.Fatalf("读取 synchronous 失败: %v", err)
	}
	if synchronous != 1 {
		t.Errorf("synchronous = %d, 期望 1(NORMAL)", synchronous)
	}

	var foreignKeys int
	if err := st.DB().QueryRow(`PRAGMA foreign_keys`).Scan(&foreignKeys); err != nil {
		t.Fatalf("读取 foreign_keys 失败: %v", err)
	}
	if foreignKeys != 1 {
		t.Errorf("foreign_keys = %d, 期望 1", foreignKeys)
	}

	var journalMode string
	if err := st.DB().QueryRow(`PRAGMA journal_mode`).Scan(&journalMode); err != nil {
		t.Fatalf("读取 journal_mode 失败: %v", err)
	}
	if !strings.EqualFold(journalMode, "wal") {
		t.Errorf("journal_mode = %q, 期望 wal", journalMode)
	}
}

// TestConcurrentReads 验证连接池放开后并发读不会触发 database is locked。
func TestConcurrentReads(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "embyx.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				var total int
				if err := st.DB().QueryRow(`SELECT COUNT(*) FROM items`).Scan(&total); err != nil {
					t.Errorf("并发读失败: %v", err)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func TestOpenRejectsMismatchedSchemaVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "embyx.db")

	st, err := Open(path)
	if err != nil {
		t.Fatalf("首次打开数据库失败: %v", err)
	}
	// 模拟旧版本留下的数据库。
	if _, err := st.DB().Exec(`PRAGMA user_version = 1`); err != nil {
		t.Fatalf("改写版本号失败: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	if _, err := Open(path); err == nil {
		t.Fatal("版本不一致时应当拒绝启动")
	}
}
