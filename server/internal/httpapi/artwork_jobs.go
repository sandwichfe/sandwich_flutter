package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"

	"embyx/internal/media"
	"embyx/internal/store"
)

// artworkJobDto 是媒体库管理页轮询的批量生成状态。
// 字段为本项目扩展（不属于 Emby 协议），命名保持 PascalCase 便于前端直接读取。
type artworkJobDto struct {
	JobId       string `json:"JobId"`
	LibraryId   string `json:"LibraryId"`
	LibraryName string `json:"LibraryName"`
	Total       int    `json:"Total"`
	Completed   int    `json:"Completed"`
	Failed      int    `json:"Failed"`
	Generated   int    `json:"Generated"`
	// PositionRatio 为 0 表示自动嗅探，否则是统一的取帧比例（0~1）。
	PositionRatio float64  `json:"PositionRatio"`
	Status        string   `json:"Status"`
	CurrentItem   string   `json:"CurrentItem"`
	Progress      float64  `json:"Progress"`
	Errors        []string `json:"Errors"`
	StartedAt     string   `json:"StartedAt"`
	FinishedAt    string   `json:"FinishedAt"`
}

func artworkJobToDto(snapshot media.ArtworkJobSnapshot) artworkJobDto {
	errs := snapshot.Errors
	if errs == nil {
		errs = []string{}
	}
	return artworkJobDto{
		JobId:         snapshot.ID,
		LibraryId:     snapshot.LibraryID,
		LibraryName:   snapshot.LibraryName,
		Total:         snapshot.Total,
		Completed:     snapshot.Completed,
		Failed:        snapshot.Failed,
		Generated:     snapshot.Generated,
		PositionRatio: snapshot.PositionRatio,
		Status:        snapshot.Status,
		CurrentItem:   snapshot.CurrentItem,
		Progress:      snapshot.Progress(),
		Errors:        errs,
		StartedAt:     snapshot.StartedAt,
		FinishedAt:    snapshot.FinishedAt,
	}
}

// handleCreateArtworkJob POST /emby/ArtworkJobs
// 正文：{ "LibraryId": "...", "Force": false, "Types": ["Primary","Backdrop"], "PositionRatio": 0 }
// PositionRatio 为 0 表示自动嗅探画面，0.02~0.98 表示按各自片长的比例取帧。
// 只处理缺图的条目：Force=false 时已经能显示出海报/封面的条目直接跳过。
func (s *Server) handleCreateArtworkJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}

	var payload struct {
		LibraryId string   `json:"LibraryId"`
		Force     bool     `json:"Force"`
		Types     []string `json:"Types"`
		// PositionRatio 由前端选择：0 表示自动嗅探，0.02~0.98 表示按各自片长的比例取帧。
		PositionRatio float64 `json:"PositionRatio"`
	}
	// 允许空正文，此时按"全部缺图条目 + 海报&封面"处理。
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	libraryID := strings.TrimSpace(payload.LibraryId)
	if libraryID == "" {
		writeError(w, http.StatusBadRequest, "缺少参数 LibraryId")
		return
	}

	library, err := s.store.LibraryByID(r.Context(), libraryID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "媒体库不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}

	items, err := s.store.LibraryVideoItems(r.Context(), library.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库条目失败")
		return
	}
	if len(items) == 0 {
		writeError(w, http.StatusBadRequest, "媒体库内没有可生成封面的视频，请先扫描媒体库")
		return
	}

	// 前端可选"自动嗅探"或"按片长某个进度取帧"，比例在这里换算成每条自己的时间点。
	positionRatio := clampArtworkRatio(payload.PositionRatio)

	imageTypes := normalizeArtworkJobTypes(payload.Types)
	targets := make([]media.ArtworkTarget, 0, len(items))
	for _, item := range items {
		needed := make([]string, 0, len(imageTypes))
		for _, imageType := range imageTypes {
			if s.needsArtwork(item.ID, imageType, payload.Force) {
				needed = append(needed, imageType)
			}
		}
		if len(needed) == 0 {
			continue
		}
		// 比例取帧时每条按自身片长定位，0 则交给生成器自动嗅探。
		var positionTicks int64
		if positionRatio > 0 && item.RunTimeTicks > 0 {
			positionTicks = int64(float64(item.RunTimeTicks) * positionRatio)
		}
		targets = append(targets, media.ArtworkTarget{
			ItemID:        item.ID,
			Name:          item.Name,
			Path:          item.Path,
			RunTimeTicks:  item.RunTimeTicks,
			PositionTicks: positionTicks,
			Types:         needed,
		})
	}
	if len(targets) == 0 {
		writeError(w, http.StatusBadRequest, "该媒体库所有条目都已有海报和封面，可勾选“全部重新生成”覆盖")
		return
	}

	snapshot, err := s.artworkJobs.Start(library.ID, library.Name, targets, positionRatio)
	if errors.Is(err, media.ErrArtworkJobRunning) {
		writeError(w, http.StatusConflict, "已有海报生成任务在运行，请等待完成或先取消")
		return
	}
	if err != nil {
		log.Printf("启动海报生成任务失败: %v", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	log.Printf("开始批量生成海报/封面: 媒体库=%s 待处理条目=%d 总计=%d",
		library.Name, len(targets), len(items))
	writeJSON(w, http.StatusOK, artworkJobToDto(snapshot))
}

// handleArtworkJob GET /emby/ArtworkJobs/{jobId} 供前端轮询进度。
func (s *Server) handleArtworkJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	snapshot, ok := s.artworkJobs.Snapshot(strings.TrimSpace(r.PathValue("jobId")))
	if !ok {
		writeError(w, http.StatusNotFound, "海报生成任务不存在")
		return
	}
	writeJSON(w, http.StatusOK, artworkJobToDto(snapshot))
}

// handleCancelArtworkJob POST /emby/ArtworkJobs/{jobId}/Cancel
func (s *Server) handleCancelArtworkJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	snapshot, err := s.artworkJobs.Cancel(strings.TrimSpace(r.PathValue("jobId")))
	if errors.Is(err, media.ErrArtworkJobNotFound) {
		writeError(w, http.StatusNotFound, "海报生成任务不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "取消任务失败")
		return
	}
	log.Printf("已请求取消海报生成任务: %s", snapshot.ID)
	writeJSON(w, http.StatusOK, artworkJobToDto(snapshot))
}

// needsArtwork 判断某个条目是否还需要生成指定类型的图片。
// 一个槽位只有一张图：有图就算满足，没有才生成。
func (s *Server) needsArtwork(itemID, imageType string, force bool) bool {
	if force {
		return true
	}
	return !s.images.HasItemImage(itemID, imageType, 0)
}

// clampArtworkRatio 把前端传来的取帧比例收口到 2%~98%，
// 0（或负数）表示不指定进度，交给自动嗅探。
func clampArtworkRatio(value float64) float64 {
	if value <= 0 {
		return 0
	}
	if value < 0.02 {
		return 0.02
	}
	if value > 0.98 {
		return 0.98
	}
	return value
}

// normalizeArtworkJobTypes 只允许海报/封面/缩略图，默认海报 + 封面。
func normalizeArtworkJobTypes(values []string) []string {
	if len(values) == 0 {
		return []string{media.ArtworkPrimary, media.ArtworkBackdrop}
	}
	allowed := map[string]bool{
		strings.ToLower(media.ArtworkPrimary):  true,
		strings.ToLower(media.ArtworkBackdrop): true,
		strings.ToLower(media.ArtworkThumb):    true,
	}
	selected := map[string]bool{}
	for _, value := range values {
		normalized := strings.ToLower(strings.TrimSpace(value))
		if !allowed[normalized] {
			continue
		}
		switch normalized {
		case "primary":
			selected[media.ArtworkPrimary] = true
		case "backdrop":
			selected[media.ArtworkBackdrop] = true
		case "thumb":
			selected[media.ArtworkThumb] = true
		}
	}
	if len(selected) == 0 {
		return []string{media.ArtworkPrimary, media.ArtworkBackdrop}
	}
	result := make([]string, 0, len(selected))
	for _, imageType := range []string{media.ArtworkPrimary, media.ArtworkBackdrop, media.ArtworkThumb} {
		if selected[imageType] {
			result = append(result, imageType)
		}
	}
	return result
}
