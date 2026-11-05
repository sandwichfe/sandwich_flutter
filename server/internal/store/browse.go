package store

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// Facet 是流派/工作室/标签这类"名称 + 条目数"的聚合结果。
// 流派与标签在库里就是字符串，ID 直接用名称；工作室保留 StableID 便于前端回传筛选。
type Facet struct {
	ID    string
	Name  string
	Count int
}

// facetCacheTTL 是分类聚合的缓存时长。数据只在扫描后变化，
// 取 1 分钟足以挡住筛选栏反复展开带来的重复聚合，又不会让新扫描结果迟迟不出现。
const facetCacheTTL = time.Minute

type facetCacheEntry struct {
	facets  []Facet
	expires time.Time
}

// Genres 用 json_each 展开 items.genres 聚合，不拆表。
// parentID 非空时只统计该媒体库内的条目（首页按库浏览时传 ParentId）。
func (s *Store) Genres(ctx context.Context, parentID string) ([]Facet, error) {
	return s.cachedFacets("genres:"+parentID, func() ([]Facet, error) {
		query := `SELECT je.value AS name, COUNT(*) AS total
			FROM items i, json_each(i.genres) je`
		where, args := facetScope(parentID)
		where = append(where, "je.value <> ''")
		query += " WHERE " + strings.Join(where, " AND ") +
			" GROUP BY je.value ORDER BY je.value COLLATE NOCASE ASC"

		return s.queryFacets(ctx, query, args, "")
	})
}

func (s *Store) Tags(ctx context.Context, parentID string) ([]Facet, error) {
	return s.cachedFacets("tags:"+parentID, func() ([]Facet, error) {
		query := `SELECT je.value AS name, COUNT(*) AS total
			FROM items i, json_each(i.tags) je`
		where, args := facetScope(parentID)
		where = append(where, "je.value <> ''")
		query += " WHERE " + strings.Join(where, " AND ") +
			" GROUP BY je.value ORDER BY je.value COLLATE NOCASE ASC"

		return s.queryFacets(ctx, query, args, "")
	})
}

// Studios 是对象数组（{Id,Name}），按名称分组，同时取回已有的稳定 ID。
func (s *Store) Studios(ctx context.Context, parentID string) ([]Facet, error) {
	return s.cachedFacets("studios:"+parentID, func() ([]Facet, error) {
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
	})
}

// cachedFacets 返回短 TTL 缓存里的聚合结果，未命中时调用 load 重算。
// 返回的切片只读，调用方不得原地修改。
func (s *Store) cachedFacets(key string, load func() ([]Facet, error)) ([]Facet, error) {
	s.facetMu.Lock()
	entry, hit := s.facetCache[key]
	s.facetMu.Unlock()
	if hit && time.Now().Before(entry.expires) {
		return entry.facets, nil
	}

	facets, err := load()
	if err != nil {
		return nil, err
	}
	s.facetMu.Lock()
	if s.facetCache == nil {
		s.facetCache = make(map[string]facetCacheEntry)
	}
	s.facetCache[key] = facetCacheEntry{facets: facets, expires: time.Now().Add(facetCacheTTL)}
	s.facetMu.Unlock()
	return facets, nil
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
