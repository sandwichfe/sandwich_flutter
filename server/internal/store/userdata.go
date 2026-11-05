package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// SetFavorite 对应 POST/DELETE /Users/{userId}/FavoriteItems/{itemId}。
func (s *Store) SetFavorite(ctx context.Context, userID, itemID string, favorite bool) (bool, error) {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO user_data (user_id, item_id, is_favorite) VALUES (?, ?, ?)
		 ON CONFLICT(user_id, item_id) DO UPDATE SET is_favorite = excluded.is_favorite`,
		userID, itemID, boolToInt(favorite),
	)
	if err != nil {
		return favorite, fmt.Errorf("更新收藏状态失败: %w", err)
	}
	return favorite, nil
}

// SetPlayed 对应 POST/DELETE /Users/{userId}/PlayedItems/{itemId}。
// 标记已看时同时清零续播位置并累计一次播放次数，列表进度条会随之消失。
func (s *Store) SetPlayed(ctx context.Context, userID, itemID string, played bool) (bool, error) {
	playCountIncrement := 0
	if played {
		playCountIncrement = 1
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO user_data (user_id, item_id, played, playback_position_ticks, play_count, last_played_date)
		 VALUES (?, ?, ?, 0, ?, ?)
		 ON CONFLICT(user_id, item_id) DO UPDATE SET
		   played = excluded.played,
		   playback_position_ticks = 0,
		   play_count = user_data.play_count + ?,
		   last_played_date = excluded.last_played_date`,
		userID, itemID, boolToInt(played), playCountIncrement, NowISO(), playCountIncrement,
	)
	if err != nil {
		return played, fmt.Errorf("更新观看状态失败: %w", err)
	}
	return played, nil
}

func (s *Store) UserDataFor(ctx context.Context, userID, itemID string) (*UserData, error) {
	var data UserData
	var isFavorite, played int
	err := s.db.QueryRowContext(ctx,
		`SELECT is_favorite, played, playback_position_ticks, play_count, last_played_date
		 FROM user_data WHERE user_id = ? AND item_id = ?`, userID, itemID,
	).Scan(&isFavorite, &played, &data.PlaybackPositionTicks, &data.PlayCount, &data.LastPlayedDate)
	if errors.Is(err, sql.ErrNoRows) {
		return &UserData{}, nil
	}
	if err != nil {
		return nil, err
	}
	data.IsFavorite = isFavorite != 0
	data.Played = played != 0
	return &data, nil
}

// SavePlaybackProgress 落库播放进度。position 达到 90% 视为看完并清零续播位置。
func (s *Store) SavePlaybackProgress(ctx context.Context, userID, itemID string, positionTicks int64, stopped bool) error {
	var runtimeTicks int64
	_ = s.db.QueryRowContext(ctx, `SELECT run_time_ticks FROM items WHERE id = ?`, itemID).Scan(&runtimeTicks)

	played := false
	if stopped && runtimeTicks > 0 && positionTicks >= runtimeTicks*9/10 {
		played = true
		positionTicks = 0
	}
	if positionTicks < 0 {
		positionTicks = 0
	}

	_, err := s.db.ExecContext(ctx,
		`INSERT INTO user_data (user_id, item_id, playback_position_ticks, played, last_played_date)
		 VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(user_id, item_id) DO UPDATE SET
		   playback_position_ticks = excluded.playback_position_ticks,
		   played = excluded.played,
		   last_played_date = excluded.last_played_date`,
		userID, itemID, positionTicks, boolToInt(played), NowISO(),
	)
	if err != nil {
		return fmt.Errorf("保存播放进度失败: %w", err)
	}
	return nil
}

// PurgeStalePlaySessions 删除 before 之前就没再上报过进度的会话。
// play_sessions 只在播放中写入，没有过期时间的话会随条目一直留在库里。
func (s *Store) PurgeStalePlaySessions(ctx context.Context, before time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx,
		`DELETE FROM play_sessions WHERE updated_at < ?`, isoTime(before))
	if err != nil {
		return 0, fmt.Errorf("清理过期播放会话失败: %w", err)
	}
	removed, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	return removed, nil
}

func (s *Store) SavePlaySession(ctx context.Context, sessionID, userID, itemID string, positionTicks int64) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO play_sessions (id, user_id, item_id, position_ticks, updated_at)
		 VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   position_ticks = excluded.position_ticks, updated_at = excluded.updated_at`,
		sessionID, userID, itemID, positionTicks, NowISO(),
	)
	return err
}
