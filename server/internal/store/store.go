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
	if _, err := db.Exec(schemaSQL); err != nil {
		return nil, fmt.Errorf("初始化表结构失败: %w", err)
	}
	store := &Store{db: db}
	if err := store.migrate(); err != nil {
		return nil, err
	}
	return store, nil
}

// migrate 处理建表语句覆盖不到的增量变更（CREATE TABLE IF NOT EXISTS 不会补列）。
func (s *Store) migrate() error {
	columns, err := s.tableColumns("libraries")
	if err != nil {
		return err
	}
	if !columns["paths"] {
		if _, err := s.db.Exec(`ALTER TABLE libraries ADD COLUMN paths TEXT NOT NULL DEFAULT '[]'`); err != nil {
			return fmt.Errorf("为 libraries 增加 paths 列失败: %w", err)
		}
	}

	// 把旧的单目录 path 回填到 paths。
	rows, err := s.db.Query(`SELECT id, path FROM libraries WHERE paths = '[]' AND path <> ''`)
	if err != nil {
		return err
	}
	type pendingRow struct{ id, path string }
	pending := make([]pendingRow, 0, 4)
	for rows.Next() {
		var row pendingRow
		if err := rows.Scan(&row.id, &row.path); err != nil {
			rows.Close()
			return err
		}
		pending = append(pending, row)
	}
	rows.Close()

	for _, row := range pending {
		if _, err := s.db.Exec(`UPDATE libraries SET paths = ? WHERE id = ?`,
			marshalJSON([]string{row.path}), row.id); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) tableColumns(table string) (map[string]bool, error) {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return nil, fmt.Errorf("读取表结构失败: %w", err)
	}
	defer rows.Close()

	columns := map[string]bool{}
	for rows.Next() {
		var (
			cid        int
			name       string
			columnType string
			notNull    int
			defaultVal sql.NullString
			primaryKey int
		)
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultVal, &primaryKey); err != nil {
			return nil, err
		}
		columns[name] = true
	}
	return columns, rows.Err()
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
