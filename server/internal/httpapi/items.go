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

	includeTypes := splitCSV(params.Get("IncludeItemTypes"))
	startIndex := atoi(params.Get("StartIndex"))
	limit := atoi(params.Get("Limit"))
	searchTerm := params.Get("SearchTerm")

	filters := splitCSV(params.Get("Filters"))
	favoriteOnly := contains(filters, "IsFavorite")

	// 人物不是 items 表的行，由演职人员字段聚合而来。
	// 注意 Filters 必须一并传下去，否则"收藏 - 演员"会返回全部人物。
	if len(includeTypes) == 1 && strings.EqualFold(includeTypes[0], "Person") {
		persons, total, err := s.store.Persons(r.Context(), userID, searchTerm, favoriteOnly, startIndex, limit)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "查询人物失败")
			return
		}
		writeJSON(w, http.StatusOK, dto.QueryResult{Items: persons, TotalRecordCount: total, StartIndex: startIndex})
		return
	}

	sortBy := splitCSV(params.Get("SortBy"))
	if len(sortBy) == 0 {
		sortBy = []string{"SortName"}
	}
	sortOrder := params.Get("SortOrder")
	if sortOrder == "" {
		sortOrder = "Ascending"
	}

	query := store.ItemQuery{
		UserID:       userID,
		ParentID:     params.Get("ParentId"),
		IncludeTypes: includeTypes,
		SearchTerm:   searchTerm,
		Years:        parseIntList(splitCSV(params.Get("Years"))),
		PersonIDs:    splitCSV(params.Get("PersonIds")),
		FavoriteOnly: favoriteOnly,
		SortBy:       sortBy,
		SortOrder:    sortOrder,
		StartIndex:   startIndex,
		Limit:        limit,
	}
	// TODO: VideoTypes 暂未实现（需要按 MediaStreams 中的编码/分辨率过滤）。

	items, total, err := s.store.QueryItems(r.Context(), query)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询条目失败")
		return
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{Items: items, TotalRecordCount: total, StartIndex: startIndex})
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

	if err := s.store.UpdateItemMetadata(r.Context(), r.PathValue("itemId"), payload); err != nil {
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
