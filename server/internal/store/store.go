package store

import (
	"crypto/rand"
	"crypto/sha1"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

type Store struct {
	db *sql.DB

	// facetCache 缓存流派/标签/工作室的聚合结果：这些数据只在扫描后才变化，
	// 而筛选栏每次展开都要对全表做 json_each + GROUP BY。TTL 很短，过期即重算。
	facetMu    sync.Mutex
	facetCache map[string]facetCacheEntry

	// tokenCache 缓存「令牌 → 用户」，避免每个请求都查一次库。登出时主动失效。
	tokenMu    sync.Mutex
	tokenCache map[string]tokenCacheEntry
}

// schemaVersion 对应 schema.sql 的表结构版本号。
// 改表结构时递增，并在 schemaMigrations 里补上「上一版 → 这一版」的语句。
const schemaVersion = 4

// schemaMigrations 是「版本 N → N+1」的升级语句。
// 新库按 schema.sql 一次建到最新；老库按 PRAGMA user_version 逐级补齐，
// 这样加索引、加列不再要求用户删库重扫。缺失步骤会明确报错而不是带着旧表结构启动。
var schemaMigrations = map[int][]string{
	// 3 → 4：补列表与续播的索引。
	3: {
		`CREATE INDEX IF NOT EXISTS idx_items_library_created ON items(library_id, date_created)`,
		`CREATE INDEX IF NOT EXISTS idx_user_data_resume ON user_data(user_id, played, last_played_date)`,
	},
}

func Open(dbPath string) (*Store, error) {
	// busy_timeout / synchronous / foreign_keys 都是「每连接」的 PRAGMA，
	// 用 Exec 设置只会作用于当时那一条连接，因此必须写在 DSN 里由驱动逐连接应用。
	dsn := "file:" + filepath.ToSlash(dbPath) +
		"?_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(1)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开数据库失败: %w", err)
	}
	// WAL 支持多读一写：读请求可以并行，写仍由 SQLite 串行化。
	maxConns := runtime.NumCPU()
	if maxConns < 2 {
		maxConns = 2
	}
	db.SetMaxOpenConns(maxConns)
	db.SetConnMaxLifetime(0)

	// journal_mode 是写进数据库文件的持久设置，一条连接设置一次即可。
	if _, err := db.Exec(`PRAGMA journal_mode = WAL;`); err != nil {
		return nil, fmt.Errorf("设置 WAL 失败: %w", err)
	}

	store := &Store{db: db}
	if err := store.prepareSchema(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

// prepareSchema 建表或把已有表结构升级到当前版本。
// 全新数据库按 schema.sql 一次性建到最新版本；已有数据库按 user_version 逐级迁移，
// 只有缺少迁移步骤（例如跨了未发布的中间版本）时才拒绝启动。
func (s *Store) prepareSchema() error {
	var version int
	if err := s.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil {
		return fmt.Errorf("读取数据库版本失败: %w", err)
	}

	if version == 0 && !s.tableExists("items") {
		if _, err := s.db.Exec(schemaSQL); err != nil {
			return fmt.Errorf("初始化表结构失败: %w", err)
		}
		if _, err := s.db.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, schemaVersion)); err != nil {
			return fmt.Errorf("写入数据库版本失败: %w", err)
		}
		return nil
	}

	if version == schemaVersion {
		return nil
	}
	if err := s.migrateSchema(version); err != nil {
		return err
	}
	return nil
}

// migrateSchema 从 from 版逐级升级到 schemaVersion，每一级在独立事务里执行。
func (s *Store) migrateSchema(from int) error {
	if from <= 0 {
		return fmt.Errorf(
			"无法识别数据库表结构版本（%d），当前程序需要版本 %d；请删除数据库文件后重启并重新扫描媒体库",
			from, schemaVersion,
		)
	}
	for version := from; version < schemaVersion; version++ {
		statements, ok := schemaMigrations[version]
		if !ok {
			return fmt.Errorf(
				"缺少数据库升级步骤 %d → %d；请删除数据库文件后重启并重新扫描媒体库",
				version, version+1,
			)
		}
		tx, err := s.db.Begin()
		if err != nil {
			return fmt.Errorf("开始数据库升级失败: %w", err)
		}
		for _, statement := range statements {
			if _, err := tx.Exec(statement); err != nil {
				_ = tx.Rollback()
				return fmt.Errorf("升级数据库到版本 %d 失败: %w", version+1, err)
			}
		}
		if _, err := tx.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, version+1)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("写入数据库版本失败: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("提交数据库升级失败: %w", err)
		}
	}
	return nil
}

func (s *Store) tableExists(table string) bool {
	var name string
	err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&name)
	return err == nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) DB() *sql.DB { return s.db }

// NewID 生成 32 位十六进制标识，形态与 Emby 的 Id 一致。
func NewID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf)
}

// StableID 由种子派生固定 ID，用于路径、姓名这类需要幂等的对象。
func StableID(seed string) string {
	sum := sha1.Sum([]byte(seed))
	return hex.EncodeToString(sum[:16])
}

// isoLayout 是库里时间字段的定宽格式：定宽 + UTC 才能直接用字符串比较先后。
const isoLayout = "2006-01-02T15:04:05.0000000Z"

func NowISO() string {
	return isoTime(time.Now())
}

// isoTime 按库内统一格式序列化时间，供与 created_at 之类的字段比较。
func isoTime(value time.Time) string {
	return value.UTC().Format(isoLayout)
}

// placeholders 构造 "?, ?, ?" 形式的占位符串。
func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

func toAny[T any](values []T) []any {
	out := make([]any, len(values))
	for i, v := range values {
		out[i] = v
	}
	return out
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
