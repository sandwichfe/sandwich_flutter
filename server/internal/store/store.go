package store

import (
	"crypto/rand"
	"crypto/sha1"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

type Store struct {
	db *sql.DB
}

// schemaVersion 对应 schema.sql 的表结构版本号。
// 改表结构时递增：本项目不提供数据迁移，启动时发现版本不一致会拒绝运行，
// 由使用者删掉数据库文件重新扫描（当前数据都可随时重建）。
const schemaVersion = 2

func Open(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("打开数据库失败: %w", err)
	}
	// SQLite 单写模型，限制连接数避免 SQLITE_BUSY。
	db.SetMaxOpenConns(1)
	db.SetConnMaxLifetime(0)

	if _, err := db.Exec(`PRAGMA journal_mode = WAL;`); err != nil {
		return nil, fmt.Errorf("设置 WAL 失败: %w", err)
	}
	if _, err := db.Exec(`PRAGMA foreign_keys = ON;`); err != nil {
		return nil, fmt.Errorf("启用外键失败: %w", err)
	}

	store := &Store{db: db}
	if err := store.prepareSchema(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

// prepareSchema 建表或校验已有表结构的版本。
// 全新数据库按 schema.sql 一次性建到最新版本；已有数据库版本不匹配时直接报错，
// 避免用旧表结构跑新代码导致字段缺失这类难排查的问题。
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

	if version != schemaVersion {
		return fmt.Errorf(
			"数据库表结构版本为 %d，当前程序需要版本 %d；请删除数据库文件后重启并重新扫描媒体库",
			version, schemaVersion,
		)
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

func NowISO() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.0000000Z")
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
