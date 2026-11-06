package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"embyx/internal/dto"
)

// personMeta 是入演员主表需要的展示信息。
type personMeta struct {
	id       string
	name     string
	imageTag string
}

// syncItemPeople 在事务内重建单个条目的演员关联，并把演员写进 persons 主表。
//
// 演员是独立主体：persons 表只增不删，条目侧的增删改只体现为 item_people 关联行
// 的变化。所以「入库」= 新建演员 + 建立关联，「更新」= 覆盖演员信息 + 重建关联，
// 「删片」= 删关联，演员本身保留。
func syncItemPeople(ctx context.Context, tx *sql.Tx, itemID string, people []dto.PersonDto) error {
	previous, err := personIDsOfItem(ctx, tx, itemID)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM item_people WHERE item_id = ?`, itemID); err != nil {
		return fmt.Errorf("清理条目演员关联失败: %w", err)
	}

	metas := make(map[string]personMeta, len(people))
	seen := make(map[string]bool, len(people))
	for index, person := range people {
		// 没有 ID 的演员无从关联（ID 由姓名派生，构建阶段就会填好）。
		if person.ID == "" {
			continue
		}
		// 同一演员可能同时是导演与编剧，role/type 不同就算两条关联。
		key := person.ID + "\x00" + person.Type + "\x00" + person.Role
		if seen[key] {
			continue
		}
		seen[key] = true
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO item_people (item_id, person_id, role, type, sort_order)
			 VALUES (?, ?, ?, ?, ?)`,
			itemID, person.ID, person.Role, person.Type, index); err != nil {
			return fmt.Errorf("写入条目演员关联失败: %w", err)
		}
		// 同一演员的多条关联只留一份展示信息；空名字不作为入库依据。
		if _, exists := metas[person.ID]; !exists {
			metas[person.ID] = personMeta{
				id:       person.ID,
				name:     strings.TrimSpace(person.Name),
				imageTag: personImageTag(person),
			}
		}
	}

	for _, meta := range metas {
		if meta.name == "" {
			continue
		}
		if err := upsertPerson(ctx, tx, meta); err != nil {
			return err
		}
	}

	// 作品数是「关联行」的派生值：新入库的演员已在 upsertPerson 里算过，
	// 这里只补算「本条目上消失」的那部分，避免每次入库都对全部演职员重复 UPDATE。
	stale := make([]string, 0, len(previous))
	for _, personID := range previous {
		if _, stillListed := metas[personID]; stillListed {
			continue
		}
		stale = append(stale, personID)
	}
	return refreshPersonCounts(ctx, tx, stale)
}

// deleteItemPeople 只删除一批条目的演员关联，演员主表与头像缓存都不动。
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
		return fmt.Errorf("清理条目演员关联失败: %w", err)
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
		return nil, fmt.Errorf("查询条目演员关联失败: %w", err)
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

// upsertPerson 写入演员主表：没有就新建，有了就用最新信息更新。
// 空值不覆盖已有值——从没有头像的条目重新入库，不应该擦掉已经导入的演员照片。
// item_count 用关联表现算（此时本条目关联已写完），不在 Go 侧维护加减计数。
func upsertPerson(ctx context.Context, tx *sql.Tx, meta personMeta) error {
	now := NowISO()
	_, err := tx.ExecContext(ctx, `
		INSERT INTO persons (person_id, name, sort_name, image_tag, item_count, created_at, updated_at)
		VALUES (?, ?, ?, ?, (SELECT COUNT(DISTINCT item_id) FROM item_people WHERE person_id = ?), ?, ?)
		ON CONFLICT(person_id) DO UPDATE SET
			name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE persons.name END,
			sort_name = CASE WHEN excluded.sort_name <> '' THEN excluded.sort_name ELSE persons.sort_name END,
			image_tag = CASE WHEN excluded.image_tag <> '' THEN excluded.image_tag ELSE persons.image_tag END,
			item_count = excluded.item_count,
			updated_at = excluded.updated_at`,
		meta.id, meta.name, meta.name, meta.imageTag, meta.id, now, now)
	if err != nil {
		return fmt.Errorf("写入演员失败: %w", err)
	}
	return nil
}

// refreshPersonCounts 重算指定演员的作品数。
// 演员行本身不删除：没有作品的演员依然保留在 persons 里，只是不出现在列表里。
func refreshPersonCounts(ctx context.Context, tx *sql.Tx, personIDs []string) error {
	for _, personID := range personIDs {
		if _, err := tx.ExecContext(ctx,
			`UPDATE persons
			 SET item_count = (SELECT COUNT(DISTINCT item_id) FROM item_people WHERE person_id = persons.person_id)
			 WHERE person_id = ?`, personID); err != nil {
			return fmt.Errorf("更新演员作品数失败: %w", err)
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

// Persons 从 persons 主表分页查询演员。
// favoriteOnly 为 true 时只返回被标记收藏的演员
// （客户端"收藏 - 演员"计数走的就是这条路径）。
func (s *Store) Persons(ctx context.Context, userID, searchTerm string, favoriteOnly bool, startIndex, limit int) ([]dto.BaseItemDto, int, error) {
	// 列表只展示有作品的演员；没有作品的演员仍在 persons 里可查。
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
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM persons p`+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("统计演员失败: %w", err)
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
		`SELECT p.person_id, p.name, p.image_tag, p.item_count FROM persons p`+whereSQL+
			` ORDER BY p.name COLLATE NOCASE ASC, p.person_id ASC LIMIT ? OFFSET ?`,
		append(args, limit, offset)...)
	if err != nil {
		return nil, 0, fmt.Errorf("查询演员失败: %w", err)
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
		persons = append(persons, personToDto(personID, name, imageTag, itemCount))
	}
	return persons, total, rows.Err()
}

// PersonByID 按 ID 查演员。演员不随影片删除，所以作品数为 0 时依然返回。
func (s *Store) PersonByID(ctx context.Context, personID string) (*dto.BaseItemDto, error) {
	var (
		name      string
		imageTag  string
		itemCount int
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT name, image_tag, item_count FROM persons WHERE person_id = ?`, personID,
	).Scan(&name, &imageTag, &itemCount)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	result := personToDto(personID, name, imageTag, itemCount)
	return &result, nil
}

// ItemPeople 返回条目当前的演职人员，信息取自 persons 主表。
// items.people 只是入库时的快照，演员改名或换头像后详情页要立刻反映最新值。
func (s *Store) ItemPeople(ctx context.Context, itemID string) ([]dto.PersonDto, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT p.person_id, p.name, p.image_tag, ip.role, ip.type
		FROM item_people ip
		JOIN persons p ON p.person_id = ip.person_id
		WHERE ip.item_id = ?
		ORDER BY ip.sort_order ASC, ip.type ASC, ip.role ASC`, itemID)
	if err != nil {
		return nil, fmt.Errorf("查询条目演员失败: %w", err)
	}
	defer rows.Close()

	people := make([]dto.PersonDto, 0, 16)
	for rows.Next() {
		var (
			personID string
			name     string
			imageTag string
			role     string
			kind     string
		)
		if err := rows.Scan(&personID, &name, &imageTag, &role, &kind); err != nil {
			return nil, err
		}
		person := dto.PersonDto{ID: personID, Name: name, Role: role, Type: kind}
		if imageTag != "" {
			person.PrimaryImageTag = imageTag
			person.ImageTags = map[string]string{"Primary": imageTag}
		}
		people = append(people, person)
	}
	return people, rows.Err()
}

func personToDto(personID, name, imageTag string, itemCount int) dto.BaseItemDto {
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
