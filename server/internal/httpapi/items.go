package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"

	"embyx/internal/dto"
	"embyx/internal/store"
)

func (s *Server) handleItems(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	params := r.URL.Query()
	query := parseItemQuery(r)

	// 人物不是 items 表的行，由演职人员字段聚合而来。
	// 注意 Filters 必须一并传下去，否则"收藏 - 演员"会返回全部人物。
	if len(query.IncludeTypes) == 1 && strings.EqualFold(query.IncludeTypes[0], "Person") {
		persons, total, err := s.store.Persons(
			r.Context(), userID, query.SearchTerm, query.FavoriteOnly, query.StartIndex, query.Limit)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "查询人物失败")
			return
		}
		writeJSON(w, http.StatusOK, dto.QueryResult{Items: persons, TotalRecordCount: total, StartIndex: query.StartIndex})
		return
	}
	// 列表默认只返回卡片字段；客户端显式要详情字段时才输出完整形态。
	query.Detail = fieldsNeedDetail(params.Get("Fields"))
	// TODO: VideoTypes 暂未实现（需要按 MediaStreams 中的编码/分辨率过滤）。

	items, total, err := s.store.QueryItems(r.Context(), query)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询条目失败")
		return
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{Items: items, TotalRecordCount: total, StartIndex: query.StartIndex})
}

// parseItemQuery 把 /Users/{id}/Items 的查询参数映射成 store.ItemQuery。
// 单独抽出来是为了能直接对参数映射做表驱动测试（最容易回归的一环）。
func parseItemQuery(r *http.Request) store.ItemQuery {
	params := r.URL.Query()
	filters := splitCSV(params.Get("Filters"))

	sortBy := splitCSV(params.Get("SortBy"))
	if len(sortBy) == 0 {
		sortBy = []string{"SortName"}
	}
	sortOrder := params.Get("SortOrder")
	if sortOrder == "" {
		sortOrder = "Ascending"
	}

	return store.ItemQuery{
		UserID:             r.PathValue("userId"),
		ParentID:           params.Get("ParentId"),
		IncludeTypes:       splitCSV(params.Get("IncludeItemTypes")),
		SearchTerm:         params.Get("SearchTerm"),
		Years:              parseIntList(splitCSV(params.Get("Years"))),
		PersonIDs:          splitCSV(params.Get("PersonIds")),
		GenreIDs:           splitCSV(params.Get("GenreIds")),
		TagIDs:             splitCSV(params.Get("TagIds")),
		StudioIDs:          splitCSV(params.Get("StudioIds")),
		FavoriteOnly:       contains(filters, "IsFavorite"),
		IsPlayed:           contains(filters, "IsPlayed"),
		IsUnplayed:         contains(filters, "IsUnplayed"),
		IsResumable:        contains(filters, "IsResumable"),
		MinCommunityRating: queryFloatPtr(r, "MinCommunityRating"),
		SortBy:             sortBy,
		SortOrder:          sortOrder,
		StartIndex:         atoi(params.Get("StartIndex")),
		Limit:              atoi(params.Get("Limit")),
	}
}

// fieldsNeedDetail 判断 Fields 参数是否要求列表里带详情字段。
// 详情页走的是 /Items/{itemId}，这里的判断只服务于少数按列表取详情的客户端。
func fieldsNeedDetail(fields string) bool {
	for _, field := range splitCSV(fields) {
		switch {
		case strings.EqualFold(field, "MediaSources"),
			strings.EqualFold(field, "People"),
			strings.EqualFold(field, "Chapters"):
			return true
		}
	}
	return false
}

// handleLatestItems 对应 GET /Users/{id}/Items/Latest。
// Emby 语义是"最新入库"：按首次入库时间倒序，直接返回数组（不带 TotalRecordCount）。
// 首页用它替代"每个媒体库各拉 10 条"。
func (s *Server) handleLatestItems(w http.ResponseWriter, r *http.Request) {
	params := r.URL.Query()
	limit := atoi(params.Get("Limit"))
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	query := store.ItemQuery{
		UserID:       r.PathValue("userId"),
		ParentID:     params.Get("ParentId"),
		IncludeTypes: splitCSV(params.Get("IncludeItemTypes")),
		SortBy:       []string{"DateCreated"},
		SortOrder:    "Descending",
		Limit:        limit,
		// 这里丢弃 total，不必再跑一次 COUNT(*)。
		SkipTotal: true,
	}
	if len(query.IncludeTypes) == 0 {
		query.IncludeTypes = []string{"Movie", "Series", "Video", "Episode"}
	}

	items, _, err := s.store.QueryItems(r.Context(), query)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询最新条目失败")
		return
	}
	writeJSON(w, http.StatusOK, items)
}

func (s *Server) handleResume(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	params := r.URL.Query()

	query := store.ItemQuery{
		UserID:       userID,
		IncludeTypes: splitCSV(params.Get("IncludeItemTypes")),
		SearchTerm:   params.Get("SearchTerm"),
		Years:        parseIntList(splitCSV(params.Get("Years"))),
		OnlyResume:   true,
		// Emby Web 默认按最近播放时间倒序。
		SortBy:     []string{"DatePlayed"},
		SortOrder:  "Descending",
		StartIndex: atoi(params.Get("StartIndex")),
		Limit:      atoi(params.Get("Limit")),
	}
	if len(query.IncludeTypes) == 0 {
		query.IncludeTypes = []string{"Movie", "Series", "Video", "Episode"}
	}

	items, total, err := s.store.QueryItems(r.Context(), query)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询继续观看失败")
		return
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{Items: items, TotalRecordCount: total})
}

func (s *Server) handleItemDetail(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	itemID := r.PathValue("itemId")

	item, err := s.store.GetItem(r.Context(), userID, itemID)
	if err == nil {
		writeJSON(w, http.StatusOK, item)
		return
	}
	if !errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusInternalServerError, "查询条目失败")
		return
	}

	// 人物条目不在 items 表中，从演职人员聚合结果里兜底。
	person, personErr := s.store.PersonByID(r.Context(), itemID)
	if personErr == nil {
		writeJSON(w, http.StatusOK, person)
		return
	}
	writeError(w, http.StatusNotFound, "条目不存在")
}

func (s *Server) handlePersons(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("UserId")
	params := r.URL.Query()

	persons, total, err := s.store.Persons(
		r.Context(), userID, params.Get("SearchTerm"),
		contains(splitCSV(params.Get("Filters")), "IsFavorite"),
		atoi(params.Get("StartIndex")), atoi(params.Get("Limit")),
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询人物失败")
		return
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{Items: persons, TotalRecordCount: total})
}

func (s *Server) handleSimilar(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("UserId")
	itemID := r.PathValue("itemId")
	limit := atoi(r.URL.Query().Get("Limit"))
	if limit <= 0 {
		limit = 18
	}

	items, err := s.store.SimilarItems(r.Context(), userID, itemID, limit)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "条目不存在")
			return
		}
		writeError(w, http.StatusInternalServerError, "查询相似条目失败")
		return
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{Items: items, TotalRecordCount: len(items)})
}

func (s *Server) handleUpdateItem(w http.ResponseWriter, r *http.Request) {
	user := currentUser(r)
	if user == nil || !user.IsAdmin {
		writeError(w, http.StatusForbidden, "需要管理员权限")
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "读取请求体失败")
		return
	}
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	itemID := r.PathValue("itemId")
	// 演员不在 items 表里，编辑演员详情（生日、简介、性别、外部编号…）走 persons 主表。
	// 两套 ID 由不同种子派生，先查演员命中率更高也不会误伤条目。
	if _, err := s.store.PersonByID(r.Context(), itemID); err == nil {
		if err := s.store.UpdatePersonMetadata(r.Context(), itemID, payload); err != nil {
			writeError(w, http.StatusInternalServerError, "保存演员信息失败")
			return
		}
		writeNoContent(w)
		return
	}

	if err := s.store.UpdateItemMetadata(r.Context(), itemID, payload); err != nil {
		writeError(w, http.StatusInternalServerError, "保存元数据失败")
		return
	}
	writeNoContent(w)
}

// handleRefreshItem 当 id 是媒体库时触发该库扫描，否则保留元数据刷新占位。
func (s *Server) handleRefreshItem(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	itemID := r.PathValue("itemId")

	if lib, err := s.store.LibraryByID(r.Context(), itemID); err == nil {
		s.scanLibraryAsync(lib)
		writeNoContent(w)
		return
	}

	log.Printf("收到元数据刷新请求 item=%s mode=%s",
		itemID, r.URL.Query().Get("MetadataRefreshMode"))
	// TODO: NFO 重新解析后在这里下发任务。
	writeNoContent(w)
}

// handleSetPlayed 对应 Emby 的 PlayedItems 资源：POST 标记已看，DELETE 标记未看。
func (s *Server) handleSetPlayed(played bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.PathValue("userId")
		itemID := r.PathValue("itemId")

		current, err := s.store.SetPlayed(r.Context(), userID, itemID, played)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "更新观看状态失败")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"Played":                current,
			"PlaybackPositionTicks": 0,
		})
	}
}

func (s *Server) handleSetFavorite(favorite bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.PathValue("userId")
		itemID := r.PathValue("itemId")

		current, err := s.store.SetFavorite(r.Context(), userID, itemID, favorite)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "更新收藏状态失败")
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"IsFavorite": current})
	}
}
