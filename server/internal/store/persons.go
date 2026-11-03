package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"embyx/internal/dto"
)

// Persons 从条目的 People 字段聚合人物列表。
// favoriteOnly 为 true 时只返回在 user_data 里被标记收藏的人物
// （客户端"收藏 - 演员"计数走的就是这条路径）。
// 数据量上升后应改为独立的 people 表 + item_people 关联表。
func (s *Store) Persons(ctx context.Context, userID, searchTerm string, favoriteOnly bool, startIndex, limit int) ([]dto.BaseItemDto, int, error) {
	favorites := map[string]bool{}
	if favoriteOnly {
		rows, err := s.db.QueryContext(ctx,
			`SELECT item_id FROM user_data WHERE user_id = ? AND is_favorite = 1`, userID)
		if err != nil {
			return nil, 0, err
		}
		defer rows.Close()
		for rows.Next() {
			var itemID string
			if err := rows.Scan(&itemID); err != nil {
				return nil, 0, err
			}
			favorites[itemID] = true
		}
		if err := rows.Err(); err != nil {
			return nil, 0, err
		}
		// 一个收藏都没有时直接返回，省掉全表扫描。
		if len(favorites) == 0 {
			return []dto.BaseItemDto{}, 0, nil
		}
	}

	rows, err := s.db.QueryContext(ctx, `SELECT people FROM items WHERE people <> '[]'`)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	seen := map[string]bool{}
	persons := make([]dto.BaseItemDto, 0, 64)
	term := strings.ToLower(strings.TrimSpace(searchTerm))

	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, 0, err
		}
		var people []dto.PersonDto
		if err := json.Unmarshal([]byte(raw), &people); err != nil {
			continue
		}
		for _, person := range people {
			if person.ID == "" || seen[person.ID] {
				continue
			}
			if favoriteOnly && !favorites[person.ID] {
				continue
			}
			if term != "" && !strings.Contains(strings.ToLower(person.Name), term) {
				continue
			}
			seen[person.ID] = true
			persons = append(persons, personToDto(person))
		}
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	sort.SliceStable(persons, func(i, j int) bool {
		return persons[i].SortName < persons[j].SortName
	})

	total := len(persons)
	if limit <= 0 {
		limit = 100
	}
	if startIndex < 0 {
		startIndex = 0
	}
	if startIndex >= total {
		return []dto.BaseItemDto{}, total, nil
	}
	end := startIndex + limit
	if end > total {
		end = total
	}
	return persons[startIndex:end], total, nil
}

func (s *Store) PersonByID(ctx context.Context, personID string) (*dto.BaseItemDto, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT people FROM items WHERE people LIKE ? LIMIT 1`,
		`%"Id":"`+personID+`"%`,
	)
	var raw string
	if err := row.Scan(&raw); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}

	var people []dto.PersonDto
	if err := json.Unmarshal([]byte(raw), &people); err != nil {
		return nil, ErrNotFound
	}
	for _, person := range people {
		if person.ID == personID {
			result := personToDto(person)
			return &result, nil
		}
	}
	return nil, ErrNotFound
}

func personToDto(person dto.PersonDto) dto.BaseItemDto {
	imageTags := person.ImageTags
	if imageTags == nil {
		imageTags = map[string]string{}
	}
	if person.PrimaryImageTag != "" {
		imageTags["Primary"] = person.PrimaryImageTag
	}
	return dto.BaseItemDto{
		ID:              person.ID,
		Name:            person.Name,
		SortName:        person.Name,
		Type:            "Person",
		Role:            person.Role,
		ImageTags:       imageTags,
		PrimaryImageTag: person.PrimaryImageTag,
	}
}
