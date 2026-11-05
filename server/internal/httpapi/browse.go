package httpapi

import (
	"context"
	"net/http"

	"embyx/internal/dto"
	"embyx/internal/store"
)

// handleGenres / handleStudios / handleTags 输出 Emby 风格的分类列表（名称 + 条目数）。
//
// 标识约定：流派与标签在库里就是字符串，返回的 Id 直接用名称；
// 工作室沿用入库时生成的 StableID。前端把 Id 原样放进
// GenreIds / TagIds / StudioIds 即可筛出该分类下的条目。
func (s *Server) handleGenres(w http.ResponseWriter, r *http.Request) {
	s.writeFacets(w, r, "Genre", "流派", s.store.Genres)
}

func (s *Server) handleStudios(w http.ResponseWriter, r *http.Request) {
	s.writeFacets(w, r, "Studio", "工作室", s.store.Studios)
}

func (s *Server) handleTags(w http.ResponseWriter, r *http.Request) {
	s.writeFacets(w, r, "Tag", "标签", s.store.Tags)
}

func (s *Server) writeFacets(w http.ResponseWriter, r *http.Request, itemType, label string,
	load func(context.Context, string) ([]store.Facet, error)) {
	facets, err := load(r.Context(), r.URL.Query().Get("ParentId"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询"+label+"失败")
		return
	}

	items := make([]dto.BaseItemDto, 0, len(facets))
	for _, facet := range facets {
		count := facet.Count
		items = append(items, dto.BaseItemDto{
			ID:         facet.ID,
			Name:       facet.Name,
			SortName:   facet.Name,
			Type:       itemType,
			ChildCount: &count,
		})
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{Items: items, TotalRecordCount: len(items)})
}
