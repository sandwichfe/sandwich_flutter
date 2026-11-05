package store

import (
	"context"
	"fmt"
	"strings"
)

// Facet 是流派/工作室/标签这类"名称 + 条目数"的聚合结果。
// 流派与标签在库里就是字符串，ID 直接用名称；工作室保留 StableID 便于前端回传筛选。
type Facet struct {
	ID    string
	Name  string
	Count int
}

// Genres 用 json_each 展开 items.genres 聚合，不拆表。
// parentID 非空时只统计该媒体库内的条目（首页按库浏览时传 ParentId）。
func (s *Store) Genres(ctx context.Context, parentID string) ([]Facet, error) {
	query := `SELECT je.value AS name, COUNT(*) AS total
		FROM items i, json_each(i.genres) je`
	where, args := facetScope(parentID)
	where = append(where, "je.value <> ''")
	query += " WHERE " + strings.Join(where, " AND ") +
		" GROUP BY je.value ORDER BY je.value COLLATE NOCASE ASC"

	return s.queryFacets(ctx, query, args, "")
}

func (s *Store) Tags(ctx context.Context, parentID string) ([]Facet, error) {
	query := `SELECT je.value AS name, COUNT(*) AS total
		FROM items i, json_each(i.tags) je`
	where, args := facetScope(parentID)
	where = append(where, "je.value <> ''")
	query += " WHERE " + strings.Join(where, " AND ") +
		" GROUP BY je.value ORDER BY je.value COLLATE NOCASE ASC"

	return s.queryFacets(ctx, query, args, "")
}

// Studios 是对象数组（{Id,Name}），按名称分组，同时取回已有的稳定 ID。
func (s *Store) Studios(ctx context.Context, parentID string) ([]Facet, error) {
	// 别名不能叫 name：items 表本身就有 name 列，SQLite 的 GROUP BY 会优先解析成列名。
	query := `SELECT je.value ->> 'Name' AS studio_name,
			MAX(COALESCE(je.value ->> 'Id', '')) AS studio_id,
			COUNT(DISTINCT i.id) AS total
		FROM items i, json_each(i.studios) je`
	where, args := facetScope(parentID)
	where = append(where, "COALESCE(je.value ->> 'Name', '') <> ''")
	query += " WHERE " + strings.Join(where, " AND ") +
		" GROUP BY studio_name ORDER BY studio_name COLLATE NOCASE ASC"

	return s.queryFacets(ctx, query, args, "studio:")
}

func facetScope(parentID string) ([]string, []any) {
	where := []string{"1 = 1"}
	args := make([]any, 0, 2)
	if strings.TrimSpace(parentID) != "" {
		where = append(where, "(i.parent_id = ? OR i.library_id = ?)")
		args = append(args, parentID, parentID)
	}
	return where, args
}

// queryFacets 读取聚合结果；idPrefix 非空时用它给没有存储 ID 的条目补一个稳定 ID。
func (s *Store) queryFacets(ctx context.Context, query string, args []any, idPrefix string) ([]Facet, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("聚合浏览分类失败: %w", err)
	}
	defer rows.Close()

	facets := make([]Facet, 0, 32)
	for rows.Next() {
		var (
			name  string
			count int
			id    string
		)
		// 流派/标签没有第二列，用 SQL 里的空常量补齐，避免写两套扫描逻辑。
		if idPrefix == "" {
			if err := rows.Scan(&name, &count); err != nil {
				return nil, err
			}
			id = name
		} else if err := rows.Scan(&name, &id, &count); err != nil {
			return nil, err
		}
		if id == "" {
			id = StableID(idPrefix + name)
		}
		facets = append(facets, Facet{ID: id, Name: name, Count: count})
	}
	return facets, rows.Err()
}
