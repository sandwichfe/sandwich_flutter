package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

var ErrDuplicateName = errors.New("已存在同名媒体库")

// Library 是 libraries 表的进程内形态。一个库可以挂多个目录。
type Library struct {
	ID             string
	Name           string
	CollectionType string
	Paths          []string
	SortOrder      int
	// PreferLocalArtwork 决定这个库优先读目录里的海报/封面，还是服务端生成的图片。
	PreferLocalArtwork bool
}

// libraryColumns 集中维护查询列，避免各处 SELECT 漏字段。
const libraryColumns = `id, name, collection_type, paths, sort_order, prefer_local_artwork`

func (s *Store) Libraries(ctx context.Context) ([]Library, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+libraryColumns+`
		 FROM libraries ORDER BY sort_order ASC, name ASC`)
	if err != nil {
		return nil, fmt.Errorf("查询媒体库失败: %w", err)
	}
	defer rows.Close()

	libraries := make([]Library, 0, 8)
	for rows.Next() {
		var (
			lib         Library
			rawPaths    string
			preferLocal int
		)
		if err := rows.Scan(&lib.ID, &lib.Name, &lib.CollectionType, &rawPaths, &lib.SortOrder, &preferLocal); err != nil {
			return nil, err
		}
		unmarshalJSON(rawPaths, &lib.Paths)
		if lib.Paths == nil {
			lib.Paths = []string{}
		}
		lib.PreferLocalArtwork = preferLocal != 0
		libraries = append(libraries, lib)
	}
	return libraries, rows.Err()
}

func (s *Store) LibraryByID(ctx context.Context, id string) (*Library, error) {
	return s.scanLibraryRow(s.db.QueryRowContext(ctx,
		`SELECT `+libraryColumns+` FROM libraries WHERE id = ?`, id))
}

func (s *Store) LibraryByName(ctx context.Context, name string) (*Library, error) {
	return s.scanLibraryRow(s.db.QueryRowContext(ctx,
		`SELECT `+libraryColumns+` FROM libraries WHERE name = ? COLLATE NOCASE`,
		strings.TrimSpace(name)))
}

func (s *Store) scanLibraryRow(row *sql.Row) (*Library, error) {
	var (
		lib         Library
		rawPaths    string
		preferLocal int
	)
	err := row.Scan(&lib.ID, &lib.Name, &lib.CollectionType, &rawPaths, &lib.SortOrder, &preferLocal)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	unmarshalJSON(rawPaths, &lib.Paths)
	if lib.Paths == nil {
		lib.Paths = []string{}
	}
	lib.PreferLocalArtwork = preferLocal != 0
	return &lib, nil
}

// SaveLibrary 新建或更新，ID 为空时自动生成并追加到排序末尾。
func (s *Store) SaveLibrary(ctx context.Context, lib Library) error {
	lib.Name = strings.TrimSpace(lib.Name)
	if lib.Name == "" {
		return errors.New("媒体库名称不能为空")
	}
	if lib.CollectionType == "" {
		lib.CollectionType = "movies"
	}

	if existing, err := s.LibraryByName(ctx, lib.Name); err == nil && existing.ID != lib.ID {
		return fmt.Errorf("%w: %s", ErrDuplicateName, lib.Name)
	} else if err != nil && !errors.Is(err, ErrNotFound) {
		return err
	}

	if lib.ID == "" {
		lib.ID = NewID()
		order, err := s.nextLibrarySortOrder(ctx)
		if err != nil {
			return err
		}
		lib.SortOrder = order
	}

	if lib.Paths == nil {
		lib.Paths = []string{}
	}

	_, err := s.db.ExecContext(ctx,
		`INSERT INTO libraries (id, name, collection_type, path, paths, sort_order, prefer_local_artwork)
		 VALUES (?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   name = excluded.name,
		   collection_type = excluded.collection_type,
		   path = excluded.path,
		   paths = excluded.paths,
		   sort_order = excluded.sort_order,
		   prefer_local_artwork = excluded.prefer_local_artwork`,
		lib.ID, lib.Name, lib.CollectionType, firstPath(lib.Paths), marshalJSON(lib.Paths), lib.SortOrder,
		boolToInt(lib.PreferLocalArtwork),
	)
	if err != nil {
		return fmt.Errorf("保存媒体库失败: %w", err)
	}
	return nil
}

func (s *Store) nextLibrarySortOrder(ctx context.Context) (int, error) {
	var maxOrder sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT MAX(sort_order) FROM libraries`).Scan(&maxOrder); err != nil {
		return 0, err
	}
	if !maxOrder.Valid {
		return 0, nil
	}
	return int(maxOrder.Int64) + 1, nil
}

// DeleteLibrary 删除库及其条目，返回被删除的条目 ID 供调用方清理图片目录。
func (s *Store) DeleteLibrary(ctx context.Context, id string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM items WHERE library_id = ? OR parent_id = ?`, id, id)
	if err != nil {
		return nil, err
	}
	itemIDs := make([]string, 0, 64)
	for rows.Next() {
		var itemID string
		if err := rows.Scan(&itemID); err != nil {
			rows.Close()
			return nil, err
		}
		itemIDs = append(itemIDs, itemID)
	}
	rows.Close()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	// 先清人物关联再删条目：关系表没有外键，顺序反了就会留下孤立行。
	if err := deleteItemPeople(ctx, tx, itemIDs); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM items WHERE library_id = ? OR parent_id = ?`, id, id); err != nil {
		return nil, fmt.Errorf("删除库内条目失败: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM libraries WHERE id = ?`, id); err != nil {
		return nil, fmt.Errorf("删除媒体库失败: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return itemIDs, nil
}

// LibraryItemRef 是清理陈旧条目所需的最小字段集合。
type LibraryItemRef struct {
	ID   string
	Path string
}

// LibraryItemRefs 返回库内所有条目的 ID 与源文件路径，供扫描后比对磁盘。
func (s *Store) LibraryItemRefs(ctx context.Context, libraryID string) ([]LibraryItemRef, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, path FROM items WHERE library_id = ? OR parent_id = ?`, libraryID, libraryID)
	if err != nil {
		return nil, fmt.Errorf("查询库内条目失败: %w", err)
	}
	defer rows.Close()

	refs := make([]LibraryItemRef, 0, 128)
	for rows.Next() {
		var ref LibraryItemRef
		if err := rows.Scan(&ref.ID, &ref.Path); err != nil {
			return nil, err
		}
		refs = append(refs, ref)
	}
	return refs, rows.Err()
}

// DeleteItems 批量删除条目，同时清掉用户数据和播放会话，避免残留孤儿行。
// 调用方负责清理条目对应的图片目录。
func (s *Store) DeleteItems(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if err := deleteItemPeople(ctx, tx, ids); err != nil {
		return err
	}

	// 用 IN (...) 一次性删除：逐条执行时条目越多持有写锁越久，
	// 会顶掉正在扫描的 4 个 worker 的 UpsertItem。
	list := "(" + placeholders(len(ids)) + ")"
	statements := []struct {
		sql  string
		desc string
	}{
		{"DELETE FROM user_data WHERE item_id IN " + list, "清理条目用户数据失败"},
		{"DELETE FROM play_sessions WHERE item_id IN " + list, "清理条目播放会话失败"},
		{"DELETE FROM items WHERE id IN " + list, "删除条目失败"},
	}
	for _, statement := range statements {
		if _, err := tx.ExecContext(ctx, statement.sql, toAny(ids)...); err != nil {
			return fmt.Errorf("%s: %w", statement.desc, err)
		}
	}
	return tx.Commit()
}

// CountItemsByLibrary 一次查出全部媒体库的条目数（库 ID → 条目数）。
// 设置页展示库列表时用它替代“每个库一条 COUNT”。
func (s *Store) CountItemsByLibrary(ctx context.Context) (map[string]int, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT library_id, COUNT(*) FROM items GROUP BY library_id`)
	if err != nil {
		return nil, fmt.Errorf("统计媒体库条目数失败: %w", err)
	}
	defer rows.Close()

	counts := make(map[string]int, 8)
	for rows.Next() {
		var (
			libraryID string
			total     int
		)
		if err := rows.Scan(&libraryID, &total); err != nil {
			return nil, err
		}
		counts[libraryID] = total
	}
	return counts, rows.Err()
}

func (s *Store) CountLibraryItems(ctx context.Context, libraryID string) (int, error) {
	var total int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM items WHERE library_id = ? OR parent_id = ?`, libraryID, libraryID).Scan(&total)
	return total, err
}

// CountCoverCandidates 统计库里可能进拼图封面的视频条目数。
// 与 RecentLibraryItemIDs 的过滤条件保持一致，用它区分"片子本来就少"和"海报还没生成完"。
func (s *Store) CountCoverCandidates(ctx context.Context, libraryID string) (int, error) {
	var total int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM items
		 WHERE (library_id = ? OR parent_id = ?)
		   AND type IN ('Movie', 'Video', 'Episode')`, libraryID, libraryID).Scan(&total)
	return total, err
}

func firstPath(paths []string) string {
	if len(paths) == 0 {
		return ""
	}
	return paths[0]
}
