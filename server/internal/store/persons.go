package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"embyx/internal/dto"
)

// personMeta 是扫描入库时能确定的那部分演员信息。
// 只有姓名（识别演员）与本地图片算新信息：生日、简介、性别、Tmdb/Imdb 等
// 一律由人物编辑接口或外部刮削维护，扫描不碰。
type personMeta struct {
	id           string
	name         string
	imageTag     string
	backdropTags []string
}

// syncItemPeople 在事务内重建单个条目的演员关联，并把演员写进 persons 主表。
//
// 核心规则：先看演员表里有没有这个人——没有就新增一行，有就只加一条影片关联，
// 演员资料保持原样。persons 表只增不删，条目侧的增删改只体现为 item_people
// 关联行的变化；删片只删关联，演员本身保留。
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
		// ID 由姓名派生，名字为空就既建不了演员行也关联不上，直接跳过。
		if person.ID == "" || strings.TrimSpace(person.Name) == "" {
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
		metas[person.ID] = mergePersonMeta(metas[person.ID], personMetaOf(person))
	}

	// 关联写完之后再落演员行：不存在就 INSERT，存在则只更新图片与作品数。
	for _, meta := range metas {
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

// personMetaOf 把条目里的演员快照转成主表写入用的结构。
func personMetaOf(person dto.PersonDto) personMeta {
	return personMeta{
		id:           person.ID,
		name:         strings.TrimSpace(person.Name),
		imageTag:     personImageTag(person),
		backdropTags: append([]string(nil), person.BackdropImageTags...),
	}
}

// mergePersonMeta 合并同一演员的多条关联：非空字段优先，避免后写的空值盖掉已有信息。
func mergePersonMeta(current, candidate personMeta) personMeta {
	if current.id == "" {
		return candidate
	}
	if candidate.name != "" {
		current.name = candidate.name
	}
	if candidate.imageTag != "" {
		current.imageTag = candidate.imageTag
	}
	if len(candidate.backdropTags) > 0 {
		current.backdropTags = candidate.backdropTags
	}
	return current
}

// upsertPerson 写入演员主表：没有就新建，有了只补本地图片与作品数。
// 姓名之外的资料（生日、简介、性别、Tmdb/Imdb…）扫描不碰，避免冲掉人工整理的信息。
// item_count 用关联表现算（此时本条目关联已写完），不在 Go 侧维护加减计数。
func upsertPerson(ctx context.Context, tx *sql.Tx, meta personMeta) error {
	backdropJSON := marshalJSON(meta.backdropTags)
	if backdropJSON == "null" {
		backdropJSON = "[]"
	}

	now := NowISO()
	_, err := tx.ExecContext(ctx, `
		INSERT INTO persons (person_id, name, sort_name, image_tag, backdrop_tags, item_count, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?,
			(SELECT COUNT(DISTINCT item_id) FROM item_people WHERE person_id = ?), ?, ?)
		ON CONFLICT(person_id) DO UPDATE SET
			-- 头像与写真来自同目录 .actors 文件，有值才覆盖；资料字段一律不动。
			image_tag = CASE WHEN excluded.image_tag <> '' THEN excluded.image_tag ELSE persons.image_tag END,
			backdrop_tags = CASE WHEN excluded.backdrop_tags <> '[]' THEN excluded.backdrop_tags ELSE persons.backdrop_tags END,
			item_count = excluded.item_count`,
		meta.id, meta.name, meta.name, meta.imageTag, backdropJSON,
		meta.id, now, now)
	if err != nil {
		return fmt.Errorf("写入演员失败: %w", err)
	}
	return nil
}

// refreshPersonCounts 重算指定演员的作品数。
// 演员行本身不删除：没有作品的演员依然保留在 persons 里，作品数为 0。
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

// Persons 从 persons 主表分页查询演员，只取列表需要的轻量字段。
// favoriteOnly 为 true 时只返回被标记收藏的演员
// （客户端"收藏 - 演员"计数走的就是这条路径）。
// 默认按姓名升序；需要切换排序时调用 PersonsSorted。
func (s *Store) Persons(ctx context.Context, userID, searchTerm string, favoriteOnly bool, startIndex, limit int) ([]dto.BaseItemDto, int, error) {
	return s.PersonsSorted(ctx, userID, searchTerm, favoriteOnly, "SortName", "Ascending", startIndex, limit)
}

// PersonsSorted 在 Persons 之上接住客户端传来的排序字段
// （演员列表支持名称/年龄/出道日期/罩杯）。
func (s *Store) PersonsSorted(ctx context.Context, userID, searchTerm string, favoriteOnly bool, sortBy, sortOrder string, startIndex, limit int) ([]dto.BaseItemDto, int, error) {
	// 列表返回 persons 全表：没有作品的演员作品数为 0，但依然展示，
	// 只有搜索词与收藏筛选会额外缩小范围。
	where := make([]string, 0, 2)
	args := make([]any, 0, 2)

	if term := strings.TrimSpace(searchTerm); term != "" {
		where = append(where, "p.name LIKE ?")
		args = append(args, "%"+term+"%")
	}
	if favoriteOnly {
		where = append(where, "p.person_id IN (SELECT item_id FROM user_data WHERE user_id = ? AND is_favorite = 1)")
		args = append(args, userID)
	}
	// 没有筛选条件时不拼 WHERE，避免出现空条件的 " WHERE "。
	whereSQL := ""
	if len(where) > 0 {
		whereSQL = " WHERE " + strings.Join(where, " AND ")
	}

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
			` ORDER BY `+personOrderBy(sortBy, sortOrder)+` LIMIT ? OFFSET ?`,
		append(args, limit, offset)...)
	if err != nil {
		return nil, 0, fmt.Errorf("查询演员失败: %w", err)
	}
	defer rows.Close()

	persons := make([]dto.BaseItemDto, 0, limit)
	for rows.Next() {
		var row personRow
		if err := rows.Scan(&row.id, &row.name, &row.imageTag, &row.itemCount); err != nil {
			return nil, 0, err
		}
		persons = append(persons, row.toDto())
	}
	return persons, total, rows.Err()
}

// personOrderBy 把客户端的排序字段映射成 persons 表的列，白名单同时防注入。
// 生日、出道日期、罩杯允许为空，这些字段排序时把空值压到最后，
// 避免没录资料的演员挤在列表头部。
func personOrderBy(sortBy, sortOrder string) string {
	direction := "ASC"
	if strings.EqualFold(sortOrder, "Descending") {
		direction = "DESC"
	}

	column, ok := map[string]string{
		"SortName":     "p.sort_name COLLATE NOCASE",
		"Name":         "p.name COLLATE NOCASE",
		"BirthDate":    "p.birth_date",
		"Age":          "p.birth_date",
		"PremiereDate": "p.premiere_date",
		"CupSize":      "p.cup_size COLLATE NOCASE",
	}[sortBy]
	if !ok || column == "" {
		column = "p.sort_name COLLATE NOCASE"
	}
	// 年龄是生日的变形：生日越晚越年轻，升序要反过来查。
	if strings.EqualFold(sortBy, "Age") {
		if direction == "ASC" {
			direction = "DESC"
		} else {
			direction = "ASC"
		}
	}

	parts := make([]string, 0, 3)
	switch column {
	case "p.birth_date", "p.premiere_date", "p.cup_size COLLATE NOCASE":
		parts = append(parts, "("+column+" = '') ASC")
	}
	parts = append(parts, column+" "+direction)
	// 追加密钥保证分页结果稳定，否则同值行的顺序可能每次不同。
	parts = append(parts, "p.person_id ASC")
	return strings.Join(parts, ", ")
}

// PersonByID 按 ID 查演员详情。演员不随影片删除，所以作品数为 0 时依然返回。
func (s *Store) PersonByID(ctx context.Context, personID string) (*dto.BaseItemDto, error) {
	var row personRow
	var backdropJSON, providerJSON string
	err := s.db.QueryRowContext(ctx, `
		SELECT person_id, name, image_tag, item_count,
			backdrop_tags, birth_date, premiere_date, gender, cup_size, overview, provider_ids
		FROM persons WHERE person_id = ?`, personID,
	).Scan(&row.id, &row.name, &row.imageTag, &row.itemCount,
		&backdropJSON, &row.birthDate, &row.premiereDate, &row.gender,
		&row.cupSize, &row.overview, &providerJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	unmarshalJSON(backdropJSON, &row.backdropTags)
	unmarshalJSON(providerJSON, &row.providerIDs)
	result := row.toDto()
	return &result, nil
}

// ItemPeople 返回条目当前的演职人员，信息取自 persons 主表。
// items.people 只是入库时的快照，演员改名或换头像后详情页要立刻反映最新值。
// 这里只带卡片需要的字段，演员详情走 PersonByID。
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

// SetPersonImageTag 把演员图片的落盘结果写回演员主表，供上传/删除头像与写真后刷新标记。
// 实体不是演员（媒体库、未知 ID）时直接返回 nil，调用方按成功处理。
func (s *Store) SetPersonImageTag(ctx context.Context, personID, imageType string, index int, tag string) error {
	switch strings.ToLower(strings.TrimSpace(imageType)) {
	case "backdrop":
		var raw string
		err := s.db.QueryRowContext(ctx,
			`SELECT backdrop_tags FROM persons WHERE person_id = ?`, personID).Scan(&raw)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("读取演员写真失败: %w", err)
		}
		tags := make([]string, 0, index+1)
		unmarshalJSON(raw, &tags)
		for len(tags) <= index {
			tags = append(tags, "")
		}
		tags[index] = tag
		// 删掉最后一张时裁掉尾部空位，避免客户端拿着空 tag 去请求图片。
		for len(tags) > 0 && tags[len(tags)-1] == "" {
			tags = tags[:len(tags)-1]
		}
		if _, err := s.db.ExecContext(ctx,
			`UPDATE persons SET backdrop_tags = ?, updated_at = ? WHERE person_id = ?`,
			marshalJSON(tags), NowISO(), personID); err != nil {
			return fmt.Errorf("更新演员写真失败: %w", err)
		}
		return nil
	case "primary":
		if _, err := s.db.ExecContext(ctx,
			`UPDATE persons SET image_tag = ?, updated_at = ? WHERE person_id = ?`,
			tag, NowISO(), personID); err != nil {
			return fmt.Errorf("更新演员头像失败: %w", err)
		}
		return nil
	default:
		// 演员只有头像与写真两类图，其它类型忽略。
		return nil
	}
}

// UpdatePersonMetadata 更新演员主表里允许手动编辑的字段。
// 演员详情与条目共用 POST /emby/Items/{id}，按 ID 落到这张表。
// NFO 给不出的信息（生日、简介、性别、罩杯等）都从这里补齐。
func (s *Store) UpdatePersonMetadata(ctx context.Context, personID string, payload map[string]any) error {
	sets := make([]string, 0, 8)
	args := make([]any, 0, 10)

	setString := func(column, key string) {
		value, ok := payload[key].(string)
		if !ok {
			return
		}
		sets = append(sets, column+" = ?")
		args = append(args, strings.TrimSpace(value))
	}

	setString("name", "Name")
	setString("overview", "Overview")
	setString("birth_date", "BirthDate")
	setString("premiere_date", "PremiereDate")
	setString("gender", "Gender")
	setString("cup_size", "CupSize")

	// 记录哪些字段被手动编辑过：刮削会跳过这些字段，人工数据优先。
	if touched := touchedManualFields(payload); len(touched) > 0 {
		var existing []string
		var raw string
		if err := s.db.QueryRowContext(ctx,
			`SELECT manual_fields FROM persons WHERE person_id = ?`, personID).Scan(&raw); err == nil {
			unmarshalJSON(raw, &existing)
		}
		sets = append(sets, "manual_fields = ?")
		args = append(args, marshalJSON(mergeManualFields(existing, touched)))
	}

	if sortName, ok := payload["SortName"].(string); ok {
		sets = append(sets, "sort_name = ?")
		args = append(args, strings.TrimSpace(sortName))
	} else if name, ok := payload["Name"].(string); ok && strings.TrimSpace(name) != "" {
		// 改名没带排序名时，跟着姓名走，避免列表里还按旧名字排。
		sets = append(sets, "sort_name = ?")
		args = append(args, strings.TrimSpace(name))
	}
	if providerIDs, ok := payload["ProviderIds"].(map[string]any); ok {
		converted := make(map[string]string, len(providerIDs))
		for key, value := range providerIDs {
			converted[key] = fmt.Sprint(value)
		}
		sets = append(sets, "provider_ids = ?")
		args = append(args, marshalJSON(converted))
	}

	if len(sets) == 0 {
		return nil
	}
	sets = append(sets, "updated_at = ?")
	args = append(args, NowISO(), personID)

	if _, err := s.db.ExecContext(ctx,
		"UPDATE persons SET "+strings.Join(sets, ", ")+" WHERE person_id = ?", args...); err != nil {
		return fmt.Errorf("更新演员信息失败: %w", err)
	}
	return nil
}

// SetPersonBackdropTags 整体替换演员的写真标记（刮削用）。
// 与逐张更新的 SetPersonImageTag 相比，它能顺手清掉「这次比上次少」的残留槽位。
func (s *Store) SetPersonBackdropTags(ctx context.Context, personID string, tags []string) error {
	payload := marshalJSON(tags)
	if payload == "null" {
		payload = "[]"
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE persons SET backdrop_tags = ?, updated_at = ? WHERE person_id = ?`,
		payload, NowISO(), personID); err != nil {
		return fmt.Errorf("更新演员写真失败: %w", err)
	}
	return nil
}

// personRow 承接 persons 表的行，统一转成协议结构。
type personRow struct {
	id           string
	name         string
	imageTag     string
	backdropTags []string
	birthDate    string
	premiereDate string
	gender       string
	cupSize      string
	overview     string
	providerIDs  map[string]string
	itemCount    int
}

func (row personRow) toDto() dto.BaseItemDto {
	imageTags := map[string]string{}
	if row.imageTag != "" {
		imageTags["Primary"] = row.imageTag
	}
	count := row.itemCount
	return dto.BaseItemDto{
		ID:                row.id,
		Name:              row.name,
		SortName:          row.name,
		Type:              "Person",
		ChildCount:        &count,
		Overview:          row.overview,
		BirthDate:         row.birthDate,
		PremiereDate:      row.premiereDate,
		Gender:            row.gender,
		CupSize:           row.cupSize,
		ProviderIDs:       row.providerIDs,
		ImageTags:         imageTags,
		PrimaryImageTag:   row.imageTag,
		BackdropImageTags: row.backdropTags,
	}
}
