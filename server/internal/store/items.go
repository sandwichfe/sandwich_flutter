package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"embyx/internal/dto"
)

// Item 是 items 表的进程内形态，复杂字段用 dto 结构直存，减少层间转换。
type Item struct {
	ID        string
	LibraryID string
	ParentID  string

	Type     string
	Name     string
	SortName string
	Overview string

	ProductionYear  *int
	PremiereDate    string
	DateCreated     string
	CommunityRating *float64
	OfficialRating  string
	RunTimeTicks    int64
	Width           int
	Height          int

	Path      string
	Container string
	Size      int64
	Bitrate   int

	MediaStreams []dto.MediaStreamInfo
	Genres       []string
	Tags         []string
	Studios      []dto.NameIDPair
	People       []dto.PersonDto
	Chapters     []dto.ChapterInfo
	ProviderIDs  map[string]string
	ExternalURLs []dto.ExternalURL

	ImageTags      map[string]string
	BackdropTags   []string
	ScreenshotTags []string

	// Fingerprint 是片源 "size:mtime" 的组合，重复扫描时命中即可跳过 ffprobe。
	Fingerprint string
	// NFOMtime 是 NFO 文件的修改时间（纳秒），单独比对，改了 NFO 也要重新入库。
	NFOMtime int64
}

type UserData struct {
	IsFavorite            bool
	Played                bool
	PlaybackPositionTicks int64
	PlayCount             int
	LastPlayedDate        string
}

// ItemQuery 对应客户端 /Users/{id}/Items 的一批查询参数。
// GenreIDs / TagIDs 里放的是名称，StudioIDs 放的是 studio 的稳定 ID：
// 流派与标签在库里本来就是字符串，没有独立主键，用名称当下标最省事。
type ItemQuery struct {
	UserID string

	ItemIDs      []string
	ParentID     string
	IncludeTypes []string
	ExcludeIDs   []string
	SearchTerm   string
	Years        []int
	PersonIDs    []string
	GenreIDs     []string
	TagIDs       []string
	StudioIDs    []string
	FavoriteOnly bool
	OnlyResume   bool
	IsPlayed     bool
	IsUnplayed   bool
	IsResumable  bool
	// MinCommunityRating 为 nil 表示不按评分过滤。
	MinCommunityRating *float64

	SortBy     []string
	SortOrder  string
	StartIndex int
	Limit      int
}

type rowScanner interface {
	Scan(dest ...any) error
}

const itemColumns = `i.id, i.library_id, i.parent_id, i.type, i.name, i.sort_name, i.overview,
	i.production_year, i.premiere_date, i.date_created, i.community_rating, i.official_rating,
	i.run_time_ticks, i.width, i.height, i.path, i.container, i.size, i.bitrate,
	i.media_streams, i.genres, i.tags, i.studios, i.people, i.chapters,
	i.provider_ids, i.external_urls, i.image_tags, i.backdrop_tags, i.screenshot_tags,
	i.fingerprint, i.nfo_mtime`

const userDataColumns = `COALESCE(ud.is_favorite, 0), COALESCE(ud.played, 0),
	COALESCE(ud.playback_position_ticks, 0), COALESCE(ud.play_count, 0),
	COALESCE(ud.last_played_date, '')`

func (s *Store) QueryItems(ctx context.Context, q ItemQuery) ([]dto.BaseItemDto, int, error) {
	where := []string{"1 = 1"}
	args := []any{q.UserID}

	if len(q.ItemIDs) > 0 {
		where = append(where, "i.id IN ("+placeholders(len(q.ItemIDs))+")")
		args = append(args, toAny(q.ItemIDs)...)
	}
	if len(q.ExcludeIDs) > 0 {
		where = append(where, "i.id NOT IN ("+placeholders(len(q.ExcludeIDs))+")")
		args = append(args, toAny(q.ExcludeIDs)...)
	}
	if q.ParentID != "" {
		// 兼容早期数据：老条目的 parent_id 为空，只有 library_id，这里一并命中。
		where = append(where, "(i.parent_id = ? OR i.library_id = ?)")
		args = append(args, q.ParentID, q.ParentID)
	}
	if len(q.IncludeTypes) > 0 {
		where = append(where, "i.type IN ("+placeholders(len(q.IncludeTypes))+")")
		args = append(args, toAny(q.IncludeTypes)...)
	}
	if term := strings.TrimSpace(q.SearchTerm); term != "" {
		like := "%" + term + "%"
		where = append(where, "(i.name LIKE ? OR i.sort_name LIKE ? OR i.overview LIKE ?)")
		args = append(args, like, like, like)
	}
	if len(q.Years) > 0 {
		where = append(where, "i.production_year IN ("+placeholders(len(q.Years))+")")
		args = append(args, toAny(q.Years)...)
	}
	// 人物走 item_people 关联表；同一个人的多条关联（导演 + 编剧）由 EXISTS 天然去重。
	for _, personID := range q.PersonIDs {
		where = append(where, "EXISTS (SELECT 1 FROM item_people ip WHERE ip.item_id = i.id AND ip.person_id = ?)")
		args = append(args, personID)
	}
	if len(q.GenreIDs) > 0 {
		where = append(where, "EXISTS (SELECT 1 FROM json_each(i.genres) je WHERE je.value IN ("+placeholders(len(q.GenreIDs))+"))")
		args = append(args, toAny(q.GenreIDs)...)
	}
	if len(q.TagIDs) > 0 {
		where = append(where, "EXISTS (SELECT 1 FROM json_each(i.tags) je WHERE je.value IN ("+placeholders(len(q.TagIDs))+"))")
		args = append(args, toAny(q.TagIDs)...)
	}
	if len(q.StudioIDs) > 0 {
		where = append(where, "EXISTS (SELECT 1 FROM json_each(i.studios) je WHERE json_extract(je.value, '$.Id') IN ("+placeholders(len(q.StudioIDs))+"))")
		args = append(args, toAny(q.StudioIDs)...)
	}
	if q.MinCommunityRating != nil {
		where = append(where, "COALESCE(i.community_rating, 0) >= ?")
		args = append(args, *q.MinCommunityRating)
	}
	if q.FavoriteOnly {
		where = append(where, "COALESCE(ud.is_favorite, 0) = 1")
	}
	if q.OnlyResume {
		where = append(where, "COALESCE(ud.playback_position_ticks, 0) > 0 AND COALESCE(ud.played, 0) = 0")
	}
	if q.IsPlayed {
		where = append(where, "COALESCE(ud.played, 0) = 1")
	}
	if q.IsUnplayed {
		where = append(where, "COALESCE(ud.played, 0) = 0")
	}
	if q.IsResumable {
		where = append(where, "COALESCE(ud.playback_position_ticks, 0) > 0 AND COALESCE(ud.played, 0) = 0")
	}

	whereSQL := strings.Join(where, " AND ")
	fromSQL := ` FROM items i LEFT JOIN user_data ud ON ud.item_id = i.id AND ud.user_id = ?`

	var total int
	countSQL := "SELECT COUNT(*)" + fromSQL + " WHERE " + whereSQL
	if err := s.db.QueryRowContext(ctx, countSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("统计条目失败: %w", err)
	}

	limit := q.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	offset := q.StartIndex
	if offset < 0 {
		offset = 0
	}

	listArgs := append(append([]any{}, args...), limit, offset)
	listSQL := "SELECT " + itemColumns + ", " + userDataColumns + fromSQL +
		" WHERE " + whereSQL + " ORDER BY " + buildOrderBy(q.SortBy, q.SortOrder) + " LIMIT ? OFFSET ?"

	rows, err := s.db.QueryContext(ctx, listSQL, listArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("查询条目失败: %w", err)
	}
	defer rows.Close()

	items := make([]dto.BaseItemDto, 0, limit)
	for rows.Next() {
		item, data, err := scanItemRow(rows)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, item.ToDto(data))
	}
	return items, total, rows.Err()
}

func buildOrderBy(sortBy []string, sortOrder string) string {
	direction := "ASC"
	if strings.EqualFold(sortOrder, "Descending") {
		direction = "DESC"
	}
	columns := map[string]string{
		"SortName":        "i.sort_name",
		"DateCreated":     "i.date_created",
		"PremiereDate":    "i.premiere_date",
		"CommunityRating": "COALESCE(i.community_rating, 0)",
		"Runtime":         "i.run_time_ticks",
		"Height":          "i.height",
		"ProductionYear":  "COALESCE(i.production_year, 0)",
		"DatePlayed":      "COALESCE(ud.last_played_date, '')",
		"Random":          "RANDOM()",
	}

	parts := make([]string, 0, len(sortBy)+1)
	for _, name := range sortBy {
		column, ok := columns[name]
		if !ok {
			continue
		}
		if column == "RANDOM()" {
			parts = append(parts, column)
			continue
		}
		parts = append(parts, column+" "+direction)
	}
	if len(parts) == 0 {
		parts = append(parts, "i.sort_name ASC")
	}
	// 追加主键保证分页结果稳定。
	parts = append(parts, "i.id ASC")
	return strings.Join(parts, ", ")
}

func (s *Store) GetItem(ctx context.Context, userID, itemID string) (*dto.BaseItemDto, error) {
	query := "SELECT " + itemColumns + ", " + userDataColumns +
		` FROM items i LEFT JOIN user_data ud ON ud.item_id = i.id AND ud.user_id = ? WHERE i.id = ?`
	item, data, err := scanItemRow(s.db.QueryRowContext(ctx, query, userID, itemID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	result := item.ToDto(data)
	return &result, nil
}

// SimilarItems 以流派重合度做最简推荐，后续可替换为标签/向量召回。
func (s *Store) SimilarItems(ctx context.Context, userID, itemID string, limit int) ([]dto.BaseItemDto, error) {
	target, err := s.getRawItem(ctx, itemID)
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 18
	}

	where := []string{"i.id <> ?", "i.type IN ('Movie','Series','Video')"}
	args := []any{userID, itemID}
	if len(target.Genres) > 0 {
		clauses := make([]string, 0, len(target.Genres))
		for _, genre := range target.Genres {
			clauses = append(clauses, "i.genres LIKE ?")
			args = append(args, `%"`+genre+`"%`)
		}
		where = append(where, "("+strings.Join(clauses, " OR ")+")")
	}

	query := "SELECT " + itemColumns + ", " + userDataColumns +
		` FROM items i LEFT JOIN user_data ud ON ud.item_id = i.id AND ud.user_id = ?
		 WHERE ` + strings.Join(where, " AND ") +
		" ORDER BY COALESCE(i.community_rating, 0) DESC, i.sort_name ASC LIMIT ?"
	args = append(args, limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("查询相似条目失败: %w", err)
	}
	defer rows.Close()

	items := make([]dto.BaseItemDto, 0, limit)
	for rows.Next() {
		item, data, err := scanItemRow(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item.ToDto(data))
	}
	return items, rows.Err()
}

func (s *Store) getRawItem(ctx context.Context, itemID string) (*Item, error) {
	query := "SELECT " + itemColumns + ", " + userDataColumns +
		` FROM items i LEFT JOIN user_data ud ON ud.item_id = i.id AND ud.user_id = ''
		 WHERE i.id = ?`
	item, _, err := scanItemRow(s.db.QueryRowContext(ctx, query, itemID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return item, err
}

// ItemFingerprint 读取已入库条目的扫描指纹与 NFO 修改时间。
// 未入库时返回 ErrNotFound，调用方据此走完整的探测流程。
func (s *Store) ItemFingerprint(ctx context.Context, itemID string) (string, int64, error) {
	var (
		fingerprint string
		nfoMtime    int64
	)
	err := s.db.QueryRowContext(ctx,
		`SELECT fingerprint, nfo_mtime FROM items WHERE id = ?`, itemID).Scan(&fingerprint, &nfoMtime)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, ErrNotFound
	}
	return fingerprint, nfoMtime, err
}

// UpdateItemLocation 只更新路径与库归属。
// 片源被移动但内容没变时用它纠正路径，播放进度与收藏都保留在原条目上。
func (s *Store) UpdateItemLocation(ctx context.Context, itemID, libraryID, path string) error {
	if _, err := s.db.ExecContext(ctx,
		`UPDATE items SET library_id = ?, parent_id = ?, path = ? WHERE id = ?`,
		libraryID, libraryID, path, itemID); err != nil {
		return fmt.Errorf("更新条目路径失败: %w", err)
	}
	return nil
}

// 插入列顺序与 UpsertItem 的参数顺序严格一致；占位符动态生成，避免手数出错。
var itemInsertColumns = []string{
	"id", "library_id", "parent_id", "type", "name", "sort_name", "overview",
	"production_year", "premiere_date", "date_created", "community_rating", "official_rating",
	"run_time_ticks", "width", "height", "path", "container", "size", "bitrate",
	"media_streams", "genres", "tags", "studios", "people", "chapters",
	"provider_ids", "external_urls", "image_tags", "backdrop_tags", "screenshot_tags",
	"fingerprint", "nfo_mtime",
}

var upsertItemSQL = "INSERT INTO items (" + strings.Join(itemInsertColumns, ", ") +
	") VALUES (" + placeholders(len(itemInsertColumns)) + `)
ON CONFLICT(id) DO UPDATE SET
	library_id = excluded.library_id, parent_id = excluded.parent_id,
	type = excluded.type, name = excluded.name, sort_name = excluded.sort_name,
	overview = excluded.overview, production_year = excluded.production_year,
	premiere_date = excluded.premiere_date,
	-- date_created 是"首次入库时间"：重复扫描保留原值，否则每次扫描都会把它刷成当前时间。
	date_created = CASE WHEN items.date_created <> '' THEN items.date_created ELSE excluded.date_created END,
	community_rating = excluded.community_rating, official_rating = excluded.official_rating,
	run_time_ticks = excluded.run_time_ticks, width = excluded.width, height = excluded.height,
	path = excluded.path, container = excluded.container, size = excluded.size,
	bitrate = excluded.bitrate, media_streams = excluded.media_streams,
	genres = excluded.genres, tags = excluded.tags, studios = excluded.studios,
	people = excluded.people, chapters = excluded.chapters,
	provider_ids = excluded.provider_ids, external_urls = excluded.external_urls,
	image_tags = excluded.image_tags, backdrop_tags = excluded.backdrop_tags,
	screenshot_tags = excluded.screenshot_tags,
	fingerprint = excluded.fingerprint, nfo_mtime = excluded.nfo_mtime`

func (s *Store) UpsertItem(ctx context.Context, item *Item) error {
	if item.ImageTags == nil {
		item.ImageTags = map[string]string{}
	}
	if item.ProviderIDs == nil {
		item.ProviderIDs = map[string]string{}
	}

	// 条目与人物关联必须同进同出：中途失败时留下孤立的 item_people 行，
	// 人物列表的条目数就会和实际不一致。
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx, upsertItemSQL,
		item.ID, item.LibraryID, item.ParentID, item.Type, item.Name, item.SortName, item.Overview,
		item.ProductionYear, item.PremiereDate, item.DateCreated, item.CommunityRating, item.OfficialRating,
		item.RunTimeTicks, item.Width, item.Height, item.Path, item.Container, item.Size, item.Bitrate,
		marshalJSON(item.MediaStreams), marshalJSON(item.Genres), marshalJSON(item.Tags),
		marshalJSON(item.Studios), marshalJSON(item.People), marshalJSON(item.Chapters),
		marshalJSON(item.ProviderIDs), marshalJSON(item.ExternalURLs), marshalJSON(item.ImageTags),
		marshalJSON(item.BackdropTags), marshalJSON(item.ScreenshotTags),
		item.Fingerprint, item.NFOMtime,
	); err != nil {
		return fmt.Errorf("写入条目失败: %w", err)
	}

	// 人物拆表：people JSON 是权威展示数据，item_people/person_view 是查询索引。
	if err := syncItemPeople(ctx, tx, item.ID, item.People); err != nil {
		return err
	}
	return tx.Commit()
}

// UpdateItemMetadata 只覆盖编辑弹窗会修改的字段，其余保持原值。
func (s *Store) UpdateItemMetadata(ctx context.Context, itemID string, payload map[string]any) error {
	sets := make([]string, 0, 8)
	args := make([]any, 0, 10)

	setString := func(column, key string) {
		value, ok := payload[key].(string)
		if !ok {
			return
		}
		sets = append(sets, column+" = ?")
		args = append(args, value)
	}

	setString("name", "Name")
	setString("sort_name", "SortName")
	setString("overview", "Overview")
	setString("official_rating", "OfficialRating")
	setString("premiere_date", "PremiereDate")

	if year, ok := toInt(payload["ProductionYear"]); ok {
		sets = append(sets, "production_year = ?")
		args = append(args, year)
	}
	if rating, ok := toFloat(payload["CommunityRating"]); ok {
		sets = append(sets, "community_rating = ?")
		args = append(args, rating)
	}
	if genres, ok := toStrings(payload["Genres"]); ok {
		sets = append(sets, "genres = ?")
		args = append(args, marshalJSON(genres))
	}
	if tags, ok := toStrings(payload["Tags"]); ok {
		sets = append(sets, "tags = ?")
		args = append(args, marshalJSON(tags))
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
	args = append(args, itemID)
	_, err := s.db.ExecContext(ctx, "UPDATE items SET "+strings.Join(sets, ", ")+" WHERE id = ?", args...)
	if err != nil {
		return fmt.Errorf("更新元数据失败: %w", err)
	}
	return nil
}

// LibraryVideoItem 是缩略图预生成任务需要的最小条目信息。
type LibraryVideoItem struct {
	ID           string
	Name         string
	Path         string
	RunTimeTicks int64
}

// LibraryVideoItems 返回库内所有带文件路径的视频条目，供缩略图预生成任务遍历。
func (s *Store) LibraryVideoItems(ctx context.Context, libraryID string) ([]LibraryVideoItem, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, name, path, run_time_ticks FROM items
		 WHERE (library_id = ? OR parent_id = ?)
		   AND type IN ('Movie', 'Video', 'Episode')
		   AND path <> ''
		 ORDER BY sort_name ASC, name ASC`, libraryID, libraryID)
	if err != nil {
		return nil, fmt.Errorf("查询媒体库条目失败: %w", err)
	}
	defer rows.Close()

	items := make([]LibraryVideoItem, 0, 64)
	for rows.Next() {
		var item LibraryVideoItem
		if err := rows.Scan(&item.ID, &item.Name, &item.Path, &item.RunTimeTicks); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

// RecentLibraryItemIDs 按加入时间倒序返回库内视频条目的 ID，供媒体库拼图封面取材。
// 同一批导入的条目 date_created 完全相同，用 sort_name/name 兜底保证顺序稳定，
// 否则每次查询取到的"最近四部"可能顺序不同，拼图会反复重建。
func (s *Store) RecentLibraryItemIDs(ctx context.Context, libraryID string, limit int) ([]string, error) {
	if limit <= 0 {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT id FROM items
		 WHERE (library_id = ? OR parent_id = ?)
		   AND type IN ('Movie', 'Video', 'Episode')
		 ORDER BY date_created DESC, sort_name ASC, name ASC
		 LIMIT ?`, libraryID, libraryID, limit)
	if err != nil {
		return nil, fmt.Errorf("查询媒体库最近条目失败: %w", err)
	}
	defer rows.Close()

	ids := make([]string, 0, limit)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// ItemSource 是生成封面需要的条目信息：源文件路径与时长。
type ItemSource struct {
	ID           string
	Name         string
	Type         string
	Path         string
	RunTimeTicks int64
}

func (s *Store) ItemSource(ctx context.Context, itemID string) (ItemSource, error) {
	var source ItemSource
	err := s.db.QueryRowContext(ctx,
		`SELECT id, name, type, path, run_time_ticks FROM items WHERE id = ?`, itemID,
	).Scan(&source.ID, &source.Name, &source.Type, &source.Path, &source.RunTimeTicks)
	if errors.Is(err, sql.ErrNoRows) {
		return source, ErrNotFound
	}
	return source, err
}

// EnsureImageTag 只在条目还没有该类型图片标记时写入，
// 避免服务端生成的图覆盖目录导入或手动上传的 tag。
func (s *Store) EnsureImageTag(ctx context.Context, itemID, imageType, tag string) error {
	if tag == "" {
		return nil
	}

	var imageTags, backdropTags string
	err := s.db.QueryRowContext(ctx,
		`SELECT image_tags, backdrop_tags FROM items WHERE id = ?`, itemID,
	).Scan(&imageTags, &backdropTags)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	if strings.EqualFold(imageType, "Backdrop") {
		var tags []string
		unmarshalJSON(backdropTags, &tags)
		if len(tags) > 0 {
			return nil
		}
		return s.SetImageTags(ctx, itemID, "backdrop_tags", []string{tag})
	}

	parsed := map[string]string{}
	unmarshalJSON(imageTags, &parsed)
	if parsed[imageType] != "" {
		return nil
	}
	parsed[imageType] = tag
	return s.SetImageTags(ctx, itemID, "image_tags", parsed)
}

// SetImageTags 供图片上传/删除后刷新条目的图片标记。
func (s *Store) SetImageTags(ctx context.Context, itemID, column string, value any) error {
	allowed := map[string]bool{"image_tags": true, "backdrop_tags": true, "screenshot_tags": true}
	if !allowed[column] {
		return fmt.Errorf("不支持的图片列: %s", column)
	}
	_, err := s.db.ExecContext(ctx, "UPDATE items SET "+column+" = ? WHERE id = ?", marshalJSON(value), itemID)
	return err
}

func scanItemRow(scanner rowScanner) (*Item, *UserData, error) {
	var item Item
	var data UserData

	var productionYear sql.NullInt64
	var communityRating sql.NullFloat64
	var mediaStreams, genres, tags, studios, people, chapters string
	var providerIDs, externalURLs, imageTags, backdropTags, screenshotTags string
	var isFavorite, played int

	err := scanner.Scan(
		&item.ID, &item.LibraryID, &item.ParentID, &item.Type, &item.Name, &item.SortName, &item.Overview,
		&productionYear, &item.PremiereDate, &item.DateCreated, &communityRating, &item.OfficialRating,
		&item.RunTimeTicks, &item.Width, &item.Height, &item.Path, &item.Container, &item.Size, &item.Bitrate,
		&mediaStreams, &genres, &tags, &studios, &people, &chapters,
		&providerIDs, &externalURLs, &imageTags, &backdropTags, &screenshotTags,
		&item.Fingerprint, &item.NFOMtime,
		&isFavorite, &played, &data.PlaybackPositionTicks, &data.PlayCount, &data.LastPlayedDate,
	)
	if err != nil {
		return nil, nil, err
	}

	if productionYear.Valid {
		year := int(productionYear.Int64)
		item.ProductionYear = &year
	}
	if communityRating.Valid {
		rating := communityRating.Float64
		item.CommunityRating = &rating
	}

	unmarshalJSON(mediaStreams, &item.MediaStreams)
	unmarshalJSON(genres, &item.Genres)
	unmarshalJSON(tags, &item.Tags)
	unmarshalJSON(studios, &item.Studios)
	unmarshalJSON(people, &item.People)
	unmarshalJSON(chapters, &item.Chapters)
	unmarshalJSON(providerIDs, &item.ProviderIDs)
	unmarshalJSON(externalURLs, &item.ExternalURLs)
	unmarshalJSON(imageTags, &item.ImageTags)
	unmarshalJSON(backdropTags, &item.BackdropTags)
	unmarshalJSON(screenshotTags, &item.ScreenshotTags)

	data.IsFavorite = isFavorite != 0
	data.Played = played != 0
	return &item, &data, nil
}

// ToDto 把内部条目转成协议结构，字段名全部在 dto 包中定义。
func (item *Item) ToDto(data *UserData) dto.BaseItemDto {
	result := dto.BaseItemDto{
		ID:                  item.ID,
		Name:                item.Name,
		SortName:            item.SortName,
		Type:                item.Type,
		Overview:            item.Overview,
		ProductionYear:      item.ProductionYear,
		CommunityRating:     item.CommunityRating,
		OfficialRating:      item.OfficialRating,
		PremiereDate:        item.PremiereDate,
		DateCreated:         item.DateCreated,
		Path:                item.Path,
		Genres:              item.Genres,
		Tags:                item.Tags,
		Studios:             item.Studios,
		People:              item.People,
		Chapters:            item.Chapters,
		ProviderIDs:         item.ProviderIDs,
		ExternalURLs:        item.ExternalURLs,
		ImageTags:           item.ImageTags,
		BackdropImageTags:   item.BackdropTags,
		ScreenshotImageTags: item.ScreenshotTags,
		MediaSources:        []dto.MediaSourceInfo{},
	}
	if item.RunTimeTicks > 0 {
		ticks := item.RunTimeTicks
		result.RunTimeTicks = &ticks
	}
	if item.Width > 0 {
		width := item.Width
		result.Width = &width
	}
	if item.Height > 0 {
		height := item.Height
		result.Height = &height
	}
	if tag, ok := item.ImageTags["Primary"]; ok && tag != "" {
		result.PrimaryImageTag = tag
	}
	if item.Path != "" {
		result.MediaSources = []dto.MediaSourceInfo{item.ToMediaSource()}
	}
	if data != nil {
		result.UserData = &dto.UserItemDataDto{
			IsFavorite:            data.IsFavorite,
			Played:                data.Played,
			PlaybackPositionTicks: data.PlaybackPositionTicks,
			PlayCount:             data.PlayCount,
			LastPlayedDate:        data.LastPlayedDate,
		}
	}
	return result
}

// ToMediaSource 把单个文件描述成可直接 DirectPlay 的媒体源。
func (item *Item) ToMediaSource() dto.MediaSourceInfo {
	name := item.Name
	if ext := pathExt(item.Path); ext != "" {
		name = item.Name + " - " + strings.ToUpper(strings.TrimPrefix(ext, "."))
	}
	return dto.MediaSourceInfo{
		ID:                   item.ID,
		Name:                 name,
		Type:                 "Default",
		ItemID:               item.ID,
		Path:                 item.Path,
		Container:            item.Container,
		Size:                 item.Size,
		Bitrate:              item.Bitrate,
		RunTimeTicks:         item.RunTimeTicks,
		Protocol:             "File",
		IsRemote:             false,
		SupportsDirectPlay:   true,
		SupportsDirectStream: true,
		SupportsTranscoding:  false,
		MediaStreams:         item.MediaStreams,
	}
}

func pathExt(path string) string {
	index := strings.LastIndex(path, ".")
	if index < 0 {
		return ""
	}
	return path[index:]
}

func marshalJSON(value any) string {
	if value == nil {
		return "null"
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return "null"
	}
	return string(raw)
}

func unmarshalJSON[T any](raw string, dst *T) {
	if raw == "" {
		return
	}
	_ = json.Unmarshal([]byte(raw), dst)
}

func toInt(value any) (int, bool) {
	switch typed := value.(type) {
	case float64:
		return int(typed), true
	case int:
		return typed, true
	case json.Number:
		parsed, err := typed.Int64()
		return int(parsed), err == nil
	}
	return 0, false
}

func toFloat(value any) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, true
	case int:
		return float64(typed), true
	case json.Number:
		parsed, err := typed.Float64()
		return parsed, err == nil
	}
	return 0, false
}

func toStrings(value any) ([]string, bool) {
	list, ok := value.([]any)
	if !ok {
		if direct, ok := value.([]string); ok {
			return direct, true
		}
		return nil, false
	}
	out := make([]string, 0, len(list))
	for _, entry := range list {
		if text, ok := entry.(string); ok {
			out = append(out, text)
		}
	}
	return out, true
}
