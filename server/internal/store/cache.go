package store

import "context"

// CacheOwners 返回仍在使用磁盘缓存的归属，供缓存回收判断哪些文件是孤儿：
// 条目 ID → 源文件路径（空串表示源文件未知），人物 ID → 空串（只有头像缓存）。
// 条目与人物共用 data/cache 下的目录命名规则，所以放在同一张表里返回。
func (s *Store) CacheOwners(ctx context.Context) (map[string]string, error) {
	owners := make(map[string]string, 1024)

	rows, err := s.db.QueryContext(ctx, `SELECT id, path FROM items`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id, path string
		if err := rows.Scan(&id, &path); err != nil {
			rows.Close()
			return nil, err
		}
		owners[id] = path
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	// 人物头像缓存同样落在 cache/images/{personID}，漏掉这里会把演员头像当孤儿删掉。
	// 用户头像的缩放缓存也复用同一目录结构，一并登记。
	for _, query := range []string{`SELECT person_id FROM person_view`, `SELECT id FROM users`} {
		rows, err := s.db.QueryContext(ctx, query)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			if _, exists := owners[id]; !exists {
				owners[id] = ""
			}
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		rows.Close()
	}
	return owners, nil
}
