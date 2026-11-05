package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"embyx/internal/dto"
)

// personMeta 是写 person_view 需要的展示信息。
type personMeta struct {
	name     string
	imageTag string
}

// syncItemPeople 在事务内重建单个条目的 item_people 行，并刷新受影响人物的统计。
// items.people 的 JSON 仍是展示用权威数据，这张表只是让「按人物筛选」「人物列表分页」
// 不必再对 JSON 做子串匹配。
func syncItemPeople(ctx context.Context, tx *sql.Tx, itemID string, people []dto.PersonDto) error {
	previous, err := personIDsOfItem(ctx, tx, itemID)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM item_people WHERE item_id = ?`, itemID); err != nil {
		return fmt.Errorf("清理条目人物关联失败: %w", err)
	}

	metas := make(map[string]personMeta, len(people))
	seen := make(map[string]bool, len(people))
	for index, person := range people {
		if person.ID == "" {
			continue
		}
		// 同一人物可能同时是导演与编剧，role/type 不同就算两条关联。
		key := person.ID + "\x00" + person.Type + "\x00" + person.Role
		if seen[key] {
			continue
		}
		seen[key] = true
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO item_people (item_id, person_id, role, type, sort_order) VALUES (?, ?, ?, ?, ?)`,
			itemID, person.ID, person.Role, person.Type, index); err != nil {
			return fmt.Errorf("写入条目人物关联失败: %w", err)
		}
		metas[person.ID] = personMeta{name: strings.TrimSpace(person.Name), imageTag: personImageTag(person)}
	}

	// 计数依赖本条目刚写入的全部关联，必须放在插入之后。
	for personID, meta := range metas {
		if meta.name == "" {
			continue
		}
		if err := upsertPersonView(ctx, tx, personID, meta); err != nil {
			return err
		}
	}

	// 仍在这个条目上的人物，其计数已在 upsertPersonView 里重算过；
	// 只需处理"从条目前消失"的那部分，避免每次入库都对全部演职员重复 UPDATE。
	stale := make([]string, 0, len(previous))
	for _, personID := range previous {
		if _, stillListed := metas[personID]; stillListed {
			continue
		}
		stale = append(stale, personID)
	}
	return refreshPersonCounts(ctx, tx, stale)
}

// deleteItemPeople 删除一批条目的关联，并立即刷新受影响人物的计数。
// 调用方负责在此之后删除 items 行。
func deleteItemPeople(ctx context.Context, tx *sql.Tx, itemIDs []string) error {
	if len(itemIDs) == 0 {
		return nil
	}
	affected, err := personIDsOfItems(ctx, tx, itemIDs)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM item_people WHERE item_id IN (`+placeholders(len(itemIDs))+`)`,
		toAny(itemIDs)...); err != nil {
		return fmt.Errorf("清理条目人物关联失败: %w", err)
	}
	return refreshPersonCounts(ctx, tx, affected)
}

func personIDsOfItem(ctx context.Context, tx *sql.Tx, itemID string) ([]string, error) {
	return personIDsOfItems(ctx, tx, []string{itemID})
}

func personIDsOfItems(ctx context.Context, tx *sql.Tx, itemIDs []string) ([]string, error) {
	rows, err := tx.QueryContext(ctx,
		`SELECT DISTINCT person_id FROM item_people WHERE item_id IN (`+placeholders(len(itemIDs))+`)`,
		toAny(itemIDs)...)
	if err != nil {
		return nil, fmt.Errorf("查询条目人物关联失败: %w", err)
	}
	defer rows.Close()

	ids := make([]string, 0, len(itemIDs))
	for rows.Next() {
		var personID string
		if err := rows.Scan(&personID); err != nil {
			return nil, err
		}
		ids = append(ids, personID)
	}
	return ids, rows.Err()
}

// upsertPersonView 写入/更新人物汇总行。item_count 用子查询现算，
// 避免在 Go 侧维护加减计数（重复扫描、人物改名等场景容易算错）。
func upsertPersonView(ctx context.Context, tx *sql.Tx, personID string, meta personMeta) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO person_view (person_id, name, image_tag, item_count)
		VALUES (?, ?, ?, (SELECT COUNT(DISTINCT item_id) FROM item_people WHERE person_id = ?))
		ON CONFLICT(person_id) DO UPDATE SET
			name = excluded.name,
			-- 新值带图时才覆盖：没有头像的条目不应该擦掉已导入的演员照片。
			image_tag = CASE WHEN excluded.image_tag <> '' THEN excluded.image_tag ELSE person_view.image_tag END,
			item_count = excluded.item_count`,
		personID, meta.name, meta.imageTag, personID)
	if err != nil {
		return fmt.Errorf("更新人物汇总失败: %w", err)
	}
	return nil
}

// refreshPersonCounts 重算指定人物的作品数，顺带回收不再出现在任何条目里的人物。
func refreshPersonCounts(ctx context.Context, tx *sql.Tx, personIDs []string) error {
	for _, personID := range personIDs {
		if _, err := tx.ExecContext(ctx,
			`UPDATE person_view
			 SET item_count = (SELECT COUNT(DISTINCT item_id) FROM item_people WHERE person_id = person_view.person_id)
			 WHERE person_id = ?`, personID); err != nil {
			return fmt.Errorf("更新人物作品数失败: %w", err)
		}
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM person_view WHERE person_id = ? AND item_count <= 0`, personID); err != nil {
			return fmt.Errorf("清理空人物失败: %w", err)
		}
	}
	return nil
}

func personImageTag(person dto.PersonDto) string {
	if person.PrimaryImageTag != "" {
		return person.PrimaryImageTag
	}
	return person.ImageTags["Primary"]
}

// Persons 从 person_view 分页查询人物。
// favoriteOnly 为 true 时只返回被标记收藏的人物
// （客户端"收藏 - 演员"计数走的就是这条路径）。
func (s *Store) Persons(ctx context.Context, userID, searchTerm string, favoriteOnly bool, startIndex, limit int) ([]dto.BaseItemDto, int, error) {
	where := []string{"p.item_count > 0"}
	args := make([]any, 0, 2)

	if term := strings.TrimSpace(searchTerm); term != "" {
		where = append(where, "p.name LIKE ?")
		args = append(args, "%"+term+"%")
	}
	if favoriteOnly {
		where = append(where, "p.person_id IN (SELECT item_id FROM user_data WHERE user_id = ? AND is_favorite = 1)")
		args = append(args, userID)
	}
	whereSQL := " WHERE " + strings.Join(where, " AND ")

	var total int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM person_view p`+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("统计人物失败: %w", err)
	}

	if limit <= 0 {
		limit = 100
	}
	offset := startIndex
	if offset < 0 {
		offset = 0
	}
	if offset >= total {
		return []dto.BaseItemDto{}, total, nil
	}

	rows, err := s.db.QueryContext(ctx,
		`SELECT p.person_id, p.name, p.image_tag, p.item_count FROM person_view p`+whereSQL+
			` ORDER BY p.name COLLATE NOCASE ASC, p.person_id ASC LIMIT ? OFFSET ?`,
		append(args, limit, offset)...)
	if err != nil {
		return nil, 0, fmt.Errorf("查询人物失败: %w", err)
	}
	defer rows.Close()

	persons := make([]dto.BaseItemDto, 0, limit)
	for rows.Next() {
		var (
			personID  string
			name      string
			imageTag  string
			itemCount int
		)
		if err := rows.Scan(&personID, &name, &imageTag, &itemCount); err != nil {
			return nil, 0, err
		}
		persons = append(persons, personViewToDto(personID, name, imageTag, itemCount))
	}
	return persons, total, rows.Err()
}

func (s *Store) PersonByID(ctx context.Context, personID string) (*dto.BaseItemDto, error) {
	var (
		name      string
		imageTag  string
		itemCount int
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT name, image_tag, item_count FROM person_view WHERE person_id = ?`, personID,
	).Scan(&name, &imageTag, &itemCount)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	result := personViewToDto(personID, name, imageTag, itemCount)
	return &result, nil
}

func personViewToDto(personID, name, imageTag string, itemCount int) dto.BaseItemDto {
	imageTags := map[string]string{}
	if imageTag != "" {
		imageTags["Primary"] = imageTag
	}
	count := itemCount
	return dto.BaseItemDto{
		ID:              personID,
		Name:            name,
		SortName:        name,
		Type:            "Person",
		ChildCount:      &count,
		ImageTags:       imageTags,
		PrimaryImageTag: imageTag,
	}
}
