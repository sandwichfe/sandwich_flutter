package store

import (
	"database/sql"
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

// TestMigrationToPersons 模拟 5 → 6 升级：person_view 的数据搬到 persons 主表，
// 老 item_people 的重复关联被去重并补上唯一约束。
func TestMigrationToPersons(t *testing.T) {
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(filepath.Join(t.TempDir(), "old.db")))
	if err != nil {
		t.Fatalf("打开旧库失败: %v", err)
	}
	defer db.Close()

	setup := []string{
		`CREATE TABLE person_view (
			person_id  TEXT PRIMARY KEY,
			name       TEXT NOT NULL,
			image_tag  TEXT NOT NULL DEFAULT '',
			item_count INTEGER NOT NULL DEFAULT 0
		)`,
		`CREATE TABLE item_people (
			item_id    TEXT NOT NULL,
			person_id  TEXT NOT NULL,
			role       TEXT NOT NULL DEFAULT '',
			type       TEXT NOT NULL DEFAULT '',
			sort_order INTEGER NOT NULL DEFAULT 0
		)`,
		`INSERT INTO person_view (person_id, name, image_tag, item_count)
		 VALUES ('p1', '张三', 'tag1', 2)`,
		`INSERT INTO item_people (item_id, person_id, role, type, sort_order)
		 VALUES ('i1', 'p1', '主演', 'Actor', 0), ('i1', 'p1', '主演', 'Actor', 1)`,
	}
	for _, statement := range setup {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("准备旧库失败: %v", err)
		}
	}

	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range schemaMigrations[5] {
		if _, err := tx.Exec(statement); err != nil {
			_ = tx.Rollback()
			t.Fatalf("执行升级语句失败: %v", err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	var (
		name     string
		imageTag string
		count    int
	)
	if err := db.QueryRow(
		`SELECT name, image_tag, item_count FROM persons WHERE person_id = 'p1'`,
	).Scan(&name, &imageTag, &count); err != nil {
		t.Fatalf("演员主表未迁移: %v", err)
	}
	if name != "张三" || imageTag != "tag1" || count != 2 {
		t.Fatalf("迁移结果不符: name=%q image_tag=%q count=%d", name, imageTag, count)
	}

	var exists int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'person_view'`,
	).Scan(&exists); err != nil || exists != 0 {
		t.Fatalf("person_view 应被删除: %d err=%v", exists, err)
	}

	var links int
	if err := db.QueryRow(`SELECT COUNT(*) FROM item_people`).Scan(&links); err != nil || links != 1 {
		t.Fatalf("重复关联应被去重: %d err=%v", links, err)
	}
	// 唯一约束生效后，重复插入只会被忽略。
	if _, err := db.Exec(
		`INSERT OR IGNORE INTO item_people (item_id, person_id, role, type, sort_order)
		 VALUES ('i1', 'p1', '主演', 'Actor', 9)`); err != nil {
		t.Fatalf("唯一约束写入失败: %v", err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM item_people`).Scan(&links); err != nil || links != 1 {
		t.Fatalf("唯一约束未生效: %d err=%v", links, err)
	}
}
