package httpapi

import (
	"net/http"
	"time"

	"embyx/internal/media"
)

// scanStatusDto 对应 GET /Library/ScanStatus，供媒体库管理页画真实进度条。
// 字段全为小写驼峰，与前端手写的解析保持一致。
type scanStatusDto struct {
	Running     bool             `json:"running"`
	LibraryID   string           `json:"libraryId,omitempty"`
	LibraryName string           `json:"libraryName,omitempty"`
	Scanned     int              `json:"scanned"`
	Total       int              `json:"total"`
	CurrentPath string           `json:"currentPath,omitempty"`
	Failures    []scanFailureDto `json:"failures"`
	StartedAt   string           `json:"startedAt,omitempty"`
	FinishedAt  string           `json:"finishedAt,omitempty"`
}

type scanFailureDto struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

func (s *Server) handleScanStatus(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}

	var progress media.ScanProgress
	if s.scanner != nil {
		progress = s.scanner.Progress()
	}

	// failures 始终输出数组而不是 null，省得前端做空值判断。
	failures := make([]scanFailureDto, 0, len(progress.Failures))
	for _, failure := range progress.Failures {
		failures = append(failures, scanFailureDto{Path: failure.Path, Reason: failure.Reason})
	}

	writeJSON(w, http.StatusOK, scanStatusDto{
		Running:     progress.Running,
		LibraryID:   progress.LibraryID,
		LibraryName: progress.LibraryName,
		Scanned:     progress.Scanned,
		Total:       progress.Total,
		CurrentPath: progress.CurrentPath,
		Failures:    failures,
		StartedAt:   formatScanTime(progress.StartedAt),
		FinishedAt:  formatScanTime(progress.FinishedAt),
	})
}

func formatScanTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.UTC().Format(time.RFC3339)
}
