package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// 刮削结果状态：前端与日志用它区分「已匹配」「重名待确认」「没找到」。
const (
	PersonMatchMatched   = "matched"
	PersonMatchAmbiguous = "ambiguous"
	PersonMatchNotFound  = "not_found"
)

// manualFields 是手动编辑接口会锁定的字段名。
// 被锁住的字段刮削一律不覆盖，保证人工整理的内容不会被第三方数据冲掉。
var manualFields = []string{"Name", "SortName", "Overview", "BirthDate", "PremiereDate", "Gender", "CupSize", "ProviderIds"}

// ScrapedPersonData 是 TMDB 刮削回来、准备写库的演员资料。
type ScrapedPersonData struct {
	Overview    string
	BirthDate   string
	Gender      string
	ProviderIDs map[string]string
}

// PersonScrapeTarget 是刮削任务的工作单元。
// MovieTmdb/MovieNames 用于「按影片反查」与重名打分，避免只靠姓名搜索认错人。
type PersonScrapeTarget struct {
	ID           string
	Name         string
	ProviderIDs  map[string]string
	ManualFields []string
	MovieTmdb    []string
	MovieNames   []string
	ScrapedAt    string
	MatchState   string
}

// PersonScrapeTargets 列出有作品、值得刮削的演员。
// onlyMissing 为 true 时只返回还没有 Tmdb 编号或从未刮削过的人，供增量刷新使用。
func (s *Store) PersonScrapeTargets(ctx context.Context, onlyMissing bool) ([]PersonScrapeTarget, error) {
	query := `SELECT person_id, name, provider_ids, manual_fields, scraped_at, match_state
		FROM persons WHERE item_count > 0
		ORDER BY name COLLATE NOCASE ASC`
	if onlyMissing {
		query = `SELECT person_id, name, provider_ids, manual_fields, scraped_at, match_state
			FROM persons
			WHERE item_count > 0
			  AND (provider_ids NOT LIKE '%"Tmdb"%' OR scraped_at = '')
			ORDER BY name COLLATE NOCASE ASC`
	}
	rows, err := s.db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("读取待刮削演员失败: %w", err)
	}

	targets := make([]PersonScrapeTarget, 0, 128)
	for rows.Next() {
		var (
			target                   PersonScrapeTarget
			providerJSON, manualJSON string
		)
		if err := rows.Scan(&target.ID, &target.Name, &providerJSON, &manualJSON,
			&target.ScrapedAt, &target.MatchState); err != nil {
			rows.Close()
			return nil, err
		}
		unmarshalJSON(providerJSON, &target.ProviderIDs)
		unmarshalJSON(manualJSON, &target.ManualFields)
		targets = append(targets, target)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	sources, err := s.personMovieSources(ctx)
	if err != nil {
		return nil, err
	}
	for index := range targets {
		if source, ok := sources[targets[index].ID]; ok {
			targets[index].MovieTmdb = source.tmdbIDs
			targets[index].MovieNames = source.names
		}
	}
	return targets, nil
}

// PersonScrapeTargetByID 读取单个演员的刮削上下文，供人物页「刮削此人物」使用。
func (s *Store) PersonScrapeTargetByID(ctx context.Context, personID string) (*PersonScrapeTarget, error) {
	var (
		target                   PersonScrapeTarget
		providerJSON, manualJSON string
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT person_id, name, provider_ids, manual_fields, scraped_at, match_state
		FROM persons WHERE person_id = ?`, personID,
	).Scan(&target.ID, &target.Name, &providerJSON, &manualJSON, &target.ScrapedAt, &target.MatchState)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	unmarshalJSON(providerJSON, &target.ProviderIDs)
	unmarshalJSON(manualJSON, &target.ManualFields)

	sources, err := s.personMovieSources(ctx)
	if err != nil {
		return nil, err
	}
	if source, ok := sources[personID]; ok {
		target.MovieTmdb = source.tmdbIDs
		target.MovieNames = source.names
	}
	return &target, nil
}

type personMovieSource struct {
	tmdbIDs []string
	names   []string
}

// personMovieSources 一次取出每位演员最近 5 部作品的名称与 Tmdb 编号。
// 用窗口函数限制每个演员的行数，避免整张关联表都搬进内存。
func (s *Store) personMovieSources(ctx context.Context) (map[string]personMovieSource, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT person_id, name, provider_ids FROM (
			SELECT ip.person_id AS person_id, i.name AS name, i.provider_ids AS provider_ids,
				ROW_NUMBER() OVER (PARTITION BY ip.person_id ORDER BY i.date_created DESC) AS rn
			FROM item_people ip
			JOIN items i ON i.id = ip.item_id
		) WHERE rn <= 5`)
	if err != nil {
		return nil, fmt.Errorf("读取演员作品来源失败: %w", err)
	}
	defer rows.Close()

	sources := make(map[string]personMovieSource, 256)
	for rows.Next() {
		var (
			personID     string
			name         string
			providerJSON string
		)
		if err := rows.Scan(&personID, &name, &providerJSON); err != nil {
			return nil, err
		}
		source := sources[personID]
		if name != "" && len(source.names) < 5 {
			source.names = append(source.names, name)
		}
		ids := map[string]string{}
		unmarshalJSON(providerJSON, &ids)
		if tmdb := ids["Tmdb"]; tmdb != "" && len(source.tmdbIDs) < 5 {
			source.tmdbIDs = append(source.tmdbIDs, tmdb)
		}
		sources[personID] = source
	}
	return sources, rows.Err()
}

// ApplyScrapedPerson 合并一次刮削结果。
//
// 规则：手动编辑过的字段（manual_fields）永不覆盖；其余字段默认只补空值，
// force 为 true 时才用新值覆盖。provider_ids 按键合并，不清掉已有编号。
func (s *Store) ApplyScrapedPerson(ctx context.Context, personID string, data ScrapedPersonData, force bool) (bool, error) {
	var (
		overview, birthDate, gender string
		providerJSON, manualJSON    string
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT overview, birth_date, gender, provider_ids, manual_fields
		FROM persons WHERE person_id = ?`, personID,
	).Scan(&overview, &birthDate, &gender, &providerJSON, &manualJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, err
	}

	locked := make(map[string]bool, len(manualFields))
	var manual []string
	unmarshalJSON(manualJSON, &manual)
	for _, field := range manual {
		locked[field] = true
	}

	sets := make([]string, 0, 5)
	args := make([]any, 0, 6)

	addString := func(column, field, incoming, current string) {
		if incoming == "" || locked[field] {
			return
		}
		if !force && current != "" {
			return
		}
		if current == incoming {
			return
		}
		sets = append(sets, column+" = ?")
		args = append(args, incoming)
	}
	addString("overview", "Overview", data.Overview, overview)
	addString("birth_date", "BirthDate", data.BirthDate, birthDate)
	addString("gender", "Gender", data.Gender, gender)

	if !locked["ProviderIds"] && len(data.ProviderIDs) > 0 {
		merged := map[string]string{}
		unmarshalJSON(providerJSON, &merged)
		changed := false
		for key, value := range data.ProviderIDs {
			if value == "" || merged[key] == value {
				continue
			}
			merged[key] = value
			changed = true
		}
		if changed {
			sets = append(sets, "provider_ids = ?")
			args = append(args, marshalJSON(merged))
		}
	}

	sets = append(sets, "scraped_at = ?", "match_state = ?")
	args = append(args, NowISO(), PersonMatchMatched, personID)
	if _, err := s.db.ExecContext(ctx,
		"UPDATE persons SET "+strings.Join(sets, ", ")+" WHERE person_id = ?", args...); err != nil {
		return false, fmt.Errorf("写入刮削结果失败: %w", err)
	}
	return len(sets) > 2, nil
}

// touchedManualFields 列出本次编辑涉及的、需要锁定的字段名。
func touchedManualFields(payload map[string]any) []string {
	fields := make([]string, 0, len(manualFields))
	for _, field := range manualFields {
		if _, ok := payload[field]; ok {
			fields = append(fields, field)
		}
	}
	return fields
}

// mergeManualFields 合并已锁字段与新锁字段，保持稳定顺序并去重。
func mergeManualFields(existing, added []string) []string {
	seen := make(map[string]bool, len(existing)+len(added))
	result := make([]string, 0, len(existing)+len(added))
	for _, list := range [][]string{existing, added} {
		for _, field := range list {
			if field == "" || seen[field] {
				continue
			}
			seen[field] = true
			result = append(result, field)
		}
	}
	return result
}

// MarkPersonMatchState 记录「重名待确认 / 没找到」，不改动任何资料字段。
func (s *Store) MarkPersonMatchState(ctx context.Context, personID, state string) error {
	if _, err := s.db.ExecContext(ctx,
		`UPDATE persons SET scraped_at = ?, match_state = ? WHERE person_id = ?`,
		NowISO(), state, personID); err != nil {
		return fmt.Errorf("记录刮削状态失败: %w", err)
	}
	return nil
}
