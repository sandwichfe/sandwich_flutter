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
}

func (s *Store) Libraries(ctx context.Context) ([]Library, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, name, collection_type, paths, sort_order
		 FROM libraries ORDER BY sort_order ASC, name ASC`)
	if err != nil {
		return nil, fmt.Errorf("查询媒体库失败: %w", err)
	}
	defer rows.Close()

	libraries := make([]Library, 0, 8)
	for rows.Next() {
		var (
			lib      Library
			rawPaths string
		)
		if err := rows.Scan(&lib.ID, &lib.Name, &lib.CollectionType, &rawPaths, &lib.SortOrder); err != nil {
			return nil, err
		}
		unmarshalJSON(rawPaths, &lib.Paths)
		if lib.Paths == nil {
			lib.Paths = []string{}
		}
		libraries = append(libraries, lib)
	}
	return libraries, rows.Err()
}

func (s *Store) LibraryByID(ctx context.Context, id string) (*Library, error) {
	return s.scanLibraryRow(s.db.QueryRowContext(ctx,
		`SELECT id, name, collection_type, paths, sort_order FROM libraries WHERE id = ?`, id))
}

func (s *Store) LibraryByName(ctx context.Context, name string) (*Library, error) {
	return s.scanLibraryRow(s.db.QueryRowContext(ctx,
		`SELECT id, name, collection_type, paths, sort_order FROM libraries WHERE name = ? COLLATE NOCASE`,
		strings.TrimSpace(name)))
}

func (s *Store) scanLibraryRow(row *sql.Row) (*Library, error) {
	var (
		lib      Library
		rawPaths string
	)
	err := row.Scan(&lib.ID, &lib.Name, &lib.CollectionType, &rawPaths, &lib.SortOrder)
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
		`INSERT INTO libraries (id, name, collection_type, path, paths, sort_order)
		 VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   name = excluded.name,
		   collection_type = excluded.collection_type,
		   path = excluded.path,
		   paths = excluded.paths,
		   sort_order = excluded.sort_order`,
		lib.ID, lib.Name, lib.CollectionType, firstPath(lib.Paths), marshalJSON(lib.Paths), lib.SortOrder,
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

func (s *Store) CountLibraryItems(ctx context.Context, libraryID string) (int, error) {
	var total int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM items WHERE library_id = ? OR parent_id = ?`, libraryID, libraryID).Scan(&total)
	return total, err
}

func firstPath(paths []string) string {
	if len(paths) == 0 {
		return ""
	}
	return paths[0]
}
