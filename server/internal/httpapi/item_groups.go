package httpapi

import (
	"net/http"
	"strings"

	"embyx/internal/store"
)

// itemGroupPartDto 是组内一个物理文件的精简信息，够管理页核对与跳转即可。
type itemGroupPartDto struct {
	Id              string `json:"Id"`
	Name            string `json:"Name"`
	PartIndex       int    `json:"PartIndex"`
	RunTimeTicks    int64  `json:"RunTimeTicks,omitempty"`
	Path            string `json:"Path,omitempty"`
	PrimaryImageTag string `json:"PrimaryImageTag,omitempty"`
}

// itemGroupDto 是一个分片组：GroupKey 保留原始分组键，便于排查与将来做维护操作。
type itemGroupDto struct {
	GroupKey    string             `json:"GroupKey"`
	LibraryId   string             `json:"LibraryId,omitempty"`
	LibraryName string             `json:"LibraryName,omitempty"`
	Name        string             `json:"Name"`
	PartCount   int                `json:"PartCount"`
	Parts       []itemGroupPartDto `json:"Parts"`
}

type itemGroupsDto struct {
	Groups           []itemGroupDto `json:"Groups"`
	TotalRecordCount int            `json:"TotalRecordCount"`
}

// handleItemGroups 对应 GET /emby/ItemGroups（本项目扩展，需管理员）：
// 按组列出分片识别结果，供核对"哪些影片被切成了多个文件""有没有把不该合并的串到一起"。
func (s *Server) handleItemGroups(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	params := r.URL.Query()
	groups, total, err := s.store.PartGroups(r.Context(), store.PartGroupQuery{
		LibraryID:  strings.TrimSpace(params.Get("LibraryId")),
		SearchTerm: params.Get("SearchTerm"),
		// 默认只列多段组：单段组通常是"删过一段"的残留，排查时显式传 OnlyMultiple=false。
		OnlyMultiple: !strings.EqualFold(params.Get("OnlyMultiple"), "false"),
		StartIndex:   atoi(params.Get("StartIndex")),
		Limit:        atoi(params.Get("Limit")),
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询分片组失败")
		return
	}

	response := itemGroupsDto{
		Groups:           make([]itemGroupDto, 0, len(groups)),
		TotalRecordCount: total,
	}
	for _, group := range groups {
		parts := make([]itemGroupPartDto, 0, len(group.Parts))
		for _, part := range group.Parts {
			parts = append(parts, itemGroupPartDto{
				Id:              part.ID,
				Name:            part.Name,
				PartIndex:       part.PartIndex,
				RunTimeTicks:    part.RunTimeTicks,
				Path:            part.Path,
				PrimaryImageTag: part.PrimaryImageTag,
			})
		}
		response.Groups = append(response.Groups, itemGroupDto{
			GroupKey:    group.Key,
			LibraryId:   group.LibraryID,
			LibraryName: group.LibraryName,
			Name:        group.Name,
			PartCount:   group.PartCount,
			Parts:       parts,
		})
	}
	writeJSON(w, http.StatusOK, response)
}
