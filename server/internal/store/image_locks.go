package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// ImageLocked 判断某个实体（条目、人物、媒体库）的图片是否被锁定。
func (s *Store) ImageLocked(ctx context.Context, entityID string) (bool, error) {
	var mark int
	err := s.db.QueryRowContext(ctx,
		`SELECT 1 FROM image_locks WHERE entity_id = ?`, entityID).Scan(&mark)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("查询图片锁失败: %w", err)
	}
	return true, nil
}

// SetImageLocked 设置/取消图片锁。锁只挡扫描与自动重拼，手动上传/生成照常允许。
func (s *Store) SetImageLocked(ctx context.Context, entityID string, locked bool) error {
	if entityID == "" {
		return errors.New("实体 ID 不能为空")
	}
	if !locked {
		if _, err := s.db.ExecContext(ctx,
			`DELETE FROM image_locks WHERE entity_id = ?`, entityID); err != nil {
			return fmt.Errorf("解除图片锁失败: %w", err)
		}
		return nil
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO image_locks (entity_id, created_at) VALUES (?, ?)
		 ON CONFLICT(entity_id) DO NOTHING`,
		entityID, time.Now().UTC().Format(time.RFC3339)); err != nil {
		return fmt.Errorf("写入图片锁失败: %w", err)
	}
	return nil
}

// ImageLockedEntities 一次性读出全部锁，扫描开始时建内存集合。
// 大库扫描对图片判断是十万级调用，逐条查库不可取。
func (s *Store) ImageLockedEntities(ctx context.Context) (map[string]bool, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT entity_id FROM image_locks`)
	if err != nil {
		return nil, fmt.Errorf("读取图片锁失败: %w", err)
	}
	defer rows.Close()

	locked := make(map[string]bool, 32)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		locked[id] = true
	}
	return locked, rows.Err()
}
