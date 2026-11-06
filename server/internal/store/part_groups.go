package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"

	"embyx/internal/dto"
	"embyx/internal/partgroup"
)

// groupRelationPart 是 item_groups.relation 的固定值：当前只有"分片"一种关系。
const groupRelationPart = "part"

// ErrGroupMismatch 表示同组文件的分辨率或视频编码不一致，放弃分组。
// 它是 parsePartSuffix 误命中时的兜底：结构校验能拦住绝大多数错误关联。
var ErrGroupMismatch = errors.New("分片结构不一致")

// ItemGroup 是 item_groups 表的一行：一个物理文件只属于一部作品。
type ItemGroup struct {
	ItemID    string
	GroupKey  string
	PartIndex int
	PartCount int
	Relation  string
}

// execQuerier 让归属写入既能跑在独立连接上，也能跑在 UpsertItem 的事务里。
type execQuerier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// upsertItemGroup 写入归属行并刷新同组分片数。
// 只有带明确序号后缀的文件才有 PartGroupKey，普通影片在这里直接返回。
func upsertItemGroup(ctx context.Context, q execQuerier, item *Item) error {
	if item.PartGroupKey == "" {
		return nil
	}
	group := ItemGroup{
		ItemID:    item.ID,
		GroupKey:  item.PartGroupKey,
		PartIndex: item.PartIndex,
		Relation:  groupRelationPart,
	}
	if group.PartIndex <= 0 {
		group.PartIndex = 1
	}
	if err := checkGroupStructure(ctx, q, group, item.Width, item.Height,
		videoCodecOf(item.MediaStreams)); err != nil {
		return err
	}
	if _, err := q.ExecContext(ctx, `INSERT INTO item_groups
		(item_id, group_key, part_index, part_count, relation)
		VALUES (?, ?, ?, 0, ?)
		ON CONFLICT(item_id) DO UPDATE SET
			group_key = excluded.group_key,
			part_index = excluded.part_index,
			relation = excluded.relation`,
		group.ItemID, group.GroupKey, group.PartIndex, group.Relation); err != nil {
		return fmt.Errorf("写入分片归属失败: %w", err)
	}
	return refreshPartCount(ctx, q, group.GroupKey)
}

// UpsertItemGroup 供回填等独立场景使用；扫描主流程走 UpsertItem 内部的事务。
func (s *Store) UpsertItemGroup(ctx context.Context, item *Item) error {
	return upsertItemGroup(ctx, s.db, item)
}

// EnsureItemGroup 只补一次「INSERT OR IGNORE」。
// 扫描里「指纹命中就跳过、不写库」的分支用它兜底：归属行一旦缺失，
// 不重新探测也能补回来，而且完全不碰已入库的条目。
func (s *Store) EnsureItemGroup(ctx context.Context, group ItemGroup) error {
	if group.GroupKey == "" {
		return nil
	}
	relation := group.Relation
	if relation == "" {
		relation = groupRelationPart
	}
	if _, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO item_groups
		(item_id, group_key, part_index, part_count, relation)
		VALUES (?, ?, ?, 0, ?)`,
		group.ItemID, group.GroupKey, group.PartIndex, relation); err != nil {
		return fmt.Errorf("补齐分片归属失败: %w", err)
	}
	// 插入成功时 part_count 还是 0，顺手刷成当前成员数，后端不用等下一次扫描。
	return refreshPartCount(ctx, s.db, group.GroupKey)
}

// RefreshPartCount 把某个组的分片数刷成当前成员数。
// 并发扫同组两个文件时会执行两次，但子查询是实时计数，最终值都会收敛到正确结果。
func (s *Store) RefreshPartCount(ctx context.Context, groupKey string) error {
	return refreshPartCount(ctx, s.db, groupKey)
}

func refreshPartCount(ctx context.Context, q execQuerier, groupKey string) error {
	if groupKey == "" {
		return nil
	}
	if _, err := q.ExecContext(ctx, `UPDATE item_groups
		SET part_count = (SELECT COUNT(*) FROM item_groups WHERE group_key = ?)
		WHERE group_key = ?`, groupKey, groupKey); err != nil {
		return fmt.Errorf("刷新分片数量失败: %w", err)
	}
	return nil
}

// checkGroupStructure 校验同组内已入库成员的画面结构：
// 分辨率或视频编码不一致说明这两个文件并不是同一部影片的分段。
func checkGroupStructure(ctx context.Context, q execQuerier, group ItemGroup, width, height int, codec string) error {
	rows, err := q.QueryContext(ctx, `SELECT i.width, i.height, i.media_streams
		FROM item_groups g JOIN items i ON i.id = g.item_id
		WHERE g.group_key = ? AND g.item_id <> ?`, group.GroupKey, group.ItemID)
	if err != nil {
		return fmt.Errorf("校验分片结构失败: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var (
			otherWidth, otherHeight int
			streams                 string
		)
		if err := rows.Scan(&otherWidth, &otherHeight, &streams); err != nil {
			return err
		}
		if width > 0 && height > 0 && otherWidth > 0 && otherHeight > 0 &&
			(width != otherWidth || height != otherHeight) {
			return fmt.Errorf("%w: 分辨率 %dx%d 与 %dx%d 不一致",
				ErrGroupMismatch, otherWidth, otherHeight, width, height)
		}
		otherCodec := videoCodecOfJSON(streams)
		if codec != "" && otherCodec != "" && !strings.EqualFold(codec, otherCodec) {
			return fmt.Errorf("%w: 视频编码 %s 与 %s 不一致", ErrGroupMismatch, otherCodec, codec)
		}
	}
	return rows.Err()
}

// ItemGroupOf 读取单个条目的归属行；不是分片时返回 ErrNotFound。
func (s *Store) ItemGroupOf(ctx context.Context, itemID string) (ItemGroup, error) {
	var group ItemGroup
	err := s.db.QueryRowContext(ctx, `SELECT item_id, group_key, part_index, part_count, relation
		FROM item_groups WHERE item_id = ?`, itemID).
		Scan(&group.ItemID, &group.GroupKey, &group.PartIndex, &group.PartCount, &group.Relation)
	if errors.Is(err, sql.ErrNoRows) {
		return group, ErrNotFound
	}
	return group, err
}

// fillPartInfo 给详情响应补上分片序号与总数：
// 详情页拿到主接口即可画出 `1/2` 徽标，不必等兄弟接口返回。
func (s *Store) fillPartInfo(ctx context.Context, item *dto.BaseItemDto) error {
	group, err := s.ItemGroupOf(ctx, item.ID)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	index, count := group.PartIndex, group.PartCount
	item.PartIndex = &index
	item.PartCount = &count
	return nil
}

// SiblingItems 返回同组分片，按 part_index 数字升序 —— 不能按字符串排，
// 否则 `_10` 会跑到 `_2` 前面。当前条目也一并返回，前端用 IsCurrent 标记。
func (s *Store) SiblingItems(ctx context.Context, userID, itemID string) ([]dto.BaseItemDto, error) {
	group, err := s.ItemGroupOf(ctx, itemID)
	if errors.Is(err, ErrNotFound) {
		return []dto.BaseItemDto{}, nil
	}
	if err != nil {
		return nil, err
	}

	query := "SELECT " + itemColumns + ", " + userDataColumns + `, g.part_index, g.part_count
		FROM item_groups g
		JOIN items i ON i.id = g.item_id
		LEFT JOIN user_data ud ON ud.item_id = i.id AND ud.user_id = ?
		WHERE g.group_key = ?
		ORDER BY g.part_index ASC, i.sort_name ASC, i.id ASC`
	rows, err := s.db.QueryContext(ctx, query, userID, group.GroupKey)
	if err != nil {
		return nil, fmt.Errorf("查询分片列表失败: %w", err)
	}
	defer rows.Close()

	items := make([]dto.BaseItemDto, 0, 4)
	for rows.Next() {
		var (
			item       Item
			raws       itemRaws
			data       UserData
			isFavorite int
			played     int
			partIndex  int
			partCount  int
		)
		dest := append(item.scanDest(&raws),
			&isFavorite, &played, &data.PlaybackPositionTicks, &data.PlayCount, &data.LastPlayedDate,
			&partIndex, &partCount)
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		raws.decode(&item)
		data.IsFavorite = isFavorite != 0
		data.Played = played != 0

		// 分片列表只用于卡片，不需要演员与章节。
		result := item.ToDto(&data, false)
		result.PartIndex = &partIndex
		result.PartCount = &partCount
		result.IsCurrent = item.ID == itemID
		items = append(items, result)
	}
	return items, rows.Err()
}

// ---------- 分片组管理视图 ----------

// PartGroupQuery 是分片组列表的查询条件，供管理页核对自动识别结果。
type PartGroupQuery struct {
	LibraryID  string
	SearchTerm string
	// OnlyMultiple 为 true 时只返回 2 段以上的组；关掉能看到"曾经多段、删了只剩一段"的残留。
	OnlyMultiple bool
	StartIndex   int
	Limit        int
}

// PartGroup 是管理视图里的一行：一个分组及其全部成员。
type PartGroup struct {
	Key         string
	LibraryID   string
	LibraryName string
	Name        string
	PartCount   int
	Parts       []PartGroupMember
}

// PartGroupMember 是组内一个物理文件，只取管理页需要的字段。
type PartGroupMember struct {
	ID              string
	Name            string
	PartIndex       int
	RunTimeTicks    int64
	Path            string
	PrimaryImageTag string
}

// PartGroups 按组分页返回分片归属，组内成员一次取全，避免逐个组查库。
// JOIN items 天然过滤掉孤儿归属行（条目已删），列表里不会出现指向空条目的组。
func (s *Store) PartGroups(ctx context.Context, q PartGroupQuery) ([]PartGroup, int, error) {
	where := []string{"1 = 1"}
	args := []any{}
	if libraryID := strings.TrimSpace(q.LibraryID); libraryID != "" {
		where = append(where, "i.library_id = ?")
		args = append(args, libraryID)
	}
	if term := strings.TrimSpace(q.SearchTerm); term != "" {
		like := "%" + term + "%"
		where = append(where, `EXISTS (
			SELECT 1 FROM item_groups g2 JOIN items i2 ON i2.id = g2.item_id
			WHERE g2.group_key = g.group_key AND (i2.name LIKE ? OR i2.path LIKE ?))`)
		args = append(args, like, like)
	}

	fromSQL := ` FROM item_groups g JOIN items i ON i.id = g.item_id
		WHERE ` + strings.Join(where, " AND ") + ` GROUP BY g.group_key`
	havingSQL := ""
	if q.OnlyMultiple {
		havingSQL = " HAVING COUNT(*) > 1"
	}

	var total int
	countSQL := "SELECT COUNT(*) FROM (SELECT g.group_key" + fromSQL + havingSQL + ")"
	if err := s.db.QueryRowContext(ctx, countSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("统计分片组失败: %w", err)
	}

	limit := q.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 200 {
		limit = 200
	}
	offset := q.StartIndex
	if offset < 0 {
		offset = 0
	}

	listSQL := "SELECT g.group_key, COUNT(*) AS part_count" + fromSQL + havingSQL +
		// 组按成员最小序号排序，成员序号相同的组用 group_key 兜底保证分页稳定。
		" ORDER BY MIN(g.part_index) ASC, g.group_key ASC LIMIT ? OFFSET ?"
	listArgs := append(append([]any{}, args...), limit, offset)
	rows, err := s.db.QueryContext(ctx, listSQL, listArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("查询分片组失败: %w", err)
	}
	defer rows.Close()

	keys := make([]string, 0, limit)
	counts := make(map[string]int, limit)
	for rows.Next() {
		var (
			key   string
			count int
		)
		if err := rows.Scan(&key, &count); err != nil {
			return nil, 0, err
		}
		keys = append(keys, key)
		counts[key] = count
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(keys) == 0 {
		return []PartGroup{}, total, nil
	}

	members, err := s.partGroupMembers(ctx, keys)
	if err != nil {
		return nil, 0, err
	}
	libraries, err := s.Libraries(ctx)
	if err != nil {
		return nil, 0, err
	}
	libraryNames := make(map[string]string, len(libraries))
	for _, library := range libraries {
		libraryNames[library.ID] = library.Name
	}

	groups := make([]PartGroup, 0, len(keys))
	for _, key := range keys {
		parts := members[key]
		group := PartGroup{
			Key:       key,
			PartCount: counts[key],
			Parts:     parts,
			Name:      groupDisplayName(key, parts),
		}
		if len(parts) > 0 {
			group.LibraryID = groupLibraryID(key)
		}
		group.LibraryName = libraryNames[group.LibraryID]
		groups = append(groups, group)
	}
	return groups, total, nil
}

// partGroupMembers 用一次 IN 查询取回多组的全部成员，按组序号数字升序。
func (s *Store) partGroupMembers(ctx context.Context, keys []string) (map[string][]PartGroupMember, error) {
	query := `SELECT g.group_key, g.part_index, i.id, i.name, i.path, i.run_time_ticks, i.image_tags
		FROM item_groups g JOIN items i ON i.id = g.item_id
		WHERE g.group_key IN (` + placeholders(len(keys)) + `)
		ORDER BY g.group_key ASC, g.part_index ASC, i.sort_name ASC`
	rows, err := s.db.QueryContext(ctx, query, toAny(keys)...)
	if err != nil {
		return nil, fmt.Errorf("查询分片组成员失败: %w", err)
	}
	defer rows.Close()

	result := make(map[string][]PartGroupMember, len(keys))
	for rows.Next() {
		var (
			key    string
			member PartGroupMember
			tags   string
		)
		if err := rows.Scan(&key, &member.PartIndex, &member.ID, &member.Name,
			&member.Path, &member.RunTimeTicks, &tags); err != nil {
			return nil, err
		}
		parsed := map[string]string{}
		unmarshalJSON(tags, &parsed)
		member.PrimaryImageTag = parsed["Primary"]
		result[key] = append(result[key], member)
	}
	return result, rows.Err()
}

// 服务端给分片名的固定后缀 ` (n)`，展示组名时去掉，避免标题里出现两遍序号。
var partDisplaySuffix = regexp.MustCompile(`\s*\(\d{1,2}\)\s*$`)

// groupDisplayName 用组内序号最小的成员名推导组名；取不到时退回 group_key 末段。
func groupDisplayName(key string, parts []PartGroupMember) string {
	if len(parts) > 0 {
		name := strings.TrimSpace(partDisplaySuffix.ReplaceAllString(parts[0].Name, ""))
		if name != "" {
			return name
		}
	}
	if index := strings.LastIndex(key, "|"); index >= 0 {
		if tail := strings.TrimSpace(key[index+1:]); tail != "" {
			return tail
		}
	}
	return key
}

// groupLibraryID 从 group_key（libraryID|相对目录|归一化标题）里取回媒体库 ID。
func groupLibraryID(key string) string {
	if index := strings.Index(key, "|"); index > 0 {
		return key[:index]
	}
	return ""
}

// DeleteItemGroups 手动清理归属行：库内没有外键，条目删了必须跟着删，
// 否则会留下永远查不到的孤儿行，兄弟列表里也会出现指向空条目的分片。
// 删除后顺带刷新受影响组的分片数，剩下的分片才能自动变回 1。
func deleteItemGroups(ctx context.Context, tx *sql.Tx, itemIDs []string) error {
	if len(itemIDs) == 0 {
		return nil
	}
	list := "(" + placeholders(len(itemIDs)) + ")"
	rows, err := tx.QueryContext(ctx,
		`SELECT DISTINCT group_key FROM item_groups WHERE item_id IN `+list, toAny(itemIDs)...)
	if err != nil {
		return fmt.Errorf("查询待清理分片归属失败: %w", err)
	}
	keys := make([]string, 0, 4)
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			rows.Close()
			return err
		}
		keys = append(keys, key)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	if _, err := tx.ExecContext(ctx,
		`DELETE FROM item_groups WHERE item_id IN `+list, toAny(itemIDs)...); err != nil {
		return fmt.Errorf("清理分片归属失败: %w", err)
	}
	for _, key := range keys {
		if err := refreshPartCount(ctx, tx, key); err != nil {
			return err
		}
	}
	return nil
}

// BackfillItemGroups 按现存条目重新推导分片归属，供老库升级时补齐（不重扫也能生效）。
// 结构调整为：先把每个库的目录读进来，再逐条推导相对目录；无法确定库根时
// 退回条目自身的绝对目录，宁可多一次重扫覆盖，也不把不同目录的同名文件串成一组。
func (s *Store) BackfillItemGroups(ctx context.Context) error {
	libraries, err := s.Libraries(ctx)
	if err != nil {
		return err
	}
	roots := make(map[string][]string, len(libraries))
	for _, lib := range libraries {
		roots[lib.ID] = lib.Paths
	}

	rows, err := s.db.QueryContext(ctx, `SELECT id, library_id, path, width, height, media_streams
		FROM items WHERE path <> ''`)
	if err != nil {
		return fmt.Errorf("读取待回填条目失败: %w", err)
	}

	// 先读全量再逐条写：回填期间不开着游标写库，SQLite 同一连接上不允许。
	candidates := make([]*Item, 0, 256)
	for rows.Next() {
		var (
			id, libraryID, path, streams string
			width, height                int
		)
		if err := rows.Scan(&id, &libraryID, &path, &width, &height, &streams); err != nil {
			rows.Close()
			return err
		}
		base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		part, ok := partgroup.ParseSuffix(base)
		if !ok {
			continue
		}
		relDir, matched := relativeDirInRoots(roots[libraryID], path)
		if !matched {
			relDir = filepath.Dir(path)
		}
		key := partgroup.GroupKey(libraryID, relDir, part.Stem)
		if key == "" {
			continue
		}
		candidates = append(candidates, &Item{
			ID:        id,
			LibraryID: libraryID,
			Path:      path,
			Width:     width,
			Height:    height,
			// 编码只在结构校验时用到，这里直接解析出第一条视频流。
			MediaStreams: parseMediaStreams(streams),
			PartGroupKey: key,
			PartIndex:    part.Index,
		})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, item := range candidates {
		// 单条失败不影响其余条目：误命中的分片只是不参与分组。
		_ = upsertItemGroup(ctx, s.db, item)
	}
	return nil
}

// relativeDirInRoots 找出条目相对库根的目录；多目录库按顺序匹配命中的根。
func relativeDirInRoots(roots []string, path string) (string, bool) {
	for _, root := range roots {
		if root == "" {
			continue
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			continue
		}
		if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			continue
		}
		return filepath.Dir(rel), true
	}
	return "", false
}

func parseMediaStreams(raw string) []dto.MediaStreamInfo {
	if raw == "" {
		return nil
	}
	var streams []dto.MediaStreamInfo
	unmarshalJSON(raw, &streams)
	return streams
}

// videoCodecOf 取第一条视频流的编码，用于同组结构校验。
func videoCodecOf(streams []dto.MediaStreamInfo) string {
	for _, stream := range streams {
		if strings.EqualFold(stream.Type, "Video") {
			return stream.Codec
		}
	}
	return ""
}

func videoCodecOfJSON(raw string) string {
	return videoCodecOf(parseMediaStreams(raw))
}
