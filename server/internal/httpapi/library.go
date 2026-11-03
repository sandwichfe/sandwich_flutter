package httpapi

import (
	"context"
	"log"
	"net/http"

	"embyx/internal/dto"
)

func (s *Server) handleViews(w http.ResponseWriter, r *http.Request) {
	libraries, err := s.store.Libraries(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{
		Items:            libraries,
		TotalRecordCount: len(libraries),
	})
}

// handleLibraryRefresh 异步触发扫描，客户端不等扫描结果。
func (s *Server) handleLibraryRefresh(w http.ResponseWriter, r *http.Request) {
	user := currentUser(r)
	if user == nil || !user.IsAdmin {
		writeError(w, http.StatusForbidden, "需要管理员权限")
		return
	}
	if len(s.cfg.MediaRoots) == 0 {
		writeError(w, http.StatusBadRequest, "未配置 EMBYX_MEDIA_ROOTS，无法扫描")
		return
	}

	roots := append([]string(nil), s.cfg.MediaRoots...)
	go func() {
		if _, err := s.scanner.Scan(context.Background(), roots, log.Printf); err != nil {
			log.Printf("媒体库扫描失败: %v", err)
		}
	}()

	writeNoContent(w)
}
