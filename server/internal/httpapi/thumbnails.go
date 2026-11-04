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

// thumbnailJobDto 是设置页轮询的任务状态。
// 字段为本项目扩展（不属于 Emby 协议），命名保持 PascalCase 便于前端直接读取。
type thumbnailJobDto struct {
	JobId       string `json:"JobId"`
	LibraryId   string `json:"LibraryId"`
	LibraryName string `json:"LibraryName"`
	IntervalMs  int    `json:"IntervalMs"`
	Width       int    `json:"Width"`
	Total       int    `json:"Total"`
	Completed   int    `json:"Completed"`
	Failed      int    `json:"Failed"`
	Skipped     int    `json:"Skipped"`
	Status      string `json:"Status"`
	CurrentItem string `json:"CurrentItem"`
	// CurrentItemProgress 是当前条目内 0~1 的抽帧进度。
	CurrentItemProgress float64 `json:"CurrentItemProgress"`
	// 时长统一用秒，前端自行格式化成"x 小时 y 分"。
	CurrentItemDurationSeconds int64    `json:"CurrentItemDurationSeconds"`
	TotalDurationSeconds       int64    `json:"TotalDurationSeconds"`
	DoneDurationSeconds        int64    `json:"DoneDurationSeconds"`
	EstimatedFrames            int      `json:"EstimatedFrames"`
	GeneratedFrames            int      `json:"GeneratedFrames"`
	Progress                   float64  `json:"Progress"`
	Errors                     []string `json:"Errors"`
	StartedAt                  string   `json:"StartedAt"`
	FinishedAt                 string   `json:"FinishedAt"`
}

func thumbnailJobToDto(snapshot media.ThumbnailJobSnapshot) thumbnailJobDto {
	errors := snapshot.Errors
	if errors == nil {
		errors = []string{}
	}
	return thumbnailJobDto{
		JobId:                      snapshot.ID,
		LibraryId:                  snapshot.LibraryID,
		LibraryName:                snapshot.LibraryName,
		IntervalMs:                 snapshot.IntervalMs,
		Width:                      snapshot.Width,
		Total:                      snapshot.Total,
		Completed:                  snapshot.Completed,
		Failed:                     snapshot.Failed,
		Skipped:                    snapshot.Skipped,
		Status:                     snapshot.Status,
		CurrentItem:                snapshot.CurrentItem,
		CurrentItemProgress:        snapshot.CurrentItemProgress,
		CurrentItemDurationSeconds: snapshot.CurrentItemDurationSeconds,
		TotalDurationSeconds:       snapshot.TotalDurationSeconds,
		DoneDurationSeconds:        snapshot.DoneDurationSeconds,
		EstimatedFrames:            snapshot.EstimatedFrames,
		GeneratedFrames:            snapshot.GeneratedFrames,
		Progress:                   snapshot.Progress(),
		Errors:                     errors,
		StartedAt:                  snapshot.StartedAt,
		FinishedAt:                 snapshot.FinishedAt,
	}
}

// handleCreateThumbnailJob POST /ThumbnailJobs
// 正文：{ "LibraryId": "...", "IntervalSeconds": 10, "Width": 320 }
// 预生成是重活，任务在后台跑，接口立即返回初始进度。
func (s *Server) handleCreateThumbnailJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}

	var payload struct {
		LibraryId       string `json:"LibraryId"`
		IntervalSeconds int    `json:"IntervalSeconds"`
		Width           int    `json:"Width"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
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
		writeError(w, http.StatusBadRequest, "媒体库内没有可生成缩略图的视频，请先扫描媒体库")
		return
	}

	intervalSeconds := payload.IntervalSeconds
	if intervalSeconds <= 0 {
		intervalSeconds = 10
	}
	if intervalSeconds < 2 {
		intervalSeconds = 2
	}
	if intervalSeconds > 600 {
		intervalSeconds = 600
	}

	width := payload.Width
	if width <= 0 {
		width = 320
	}
	if width < 120 {
		width = 120
	}
	if width > 640 {
		width = 640
	}

	targets := make([]media.ThumbnailTarget, 0, len(items))
	for _, item := range items {
		targets = append(targets, media.ThumbnailTarget{
			ItemID: item.ID,
			Name:   item.Name,
			Path:   item.Path,
			// RunTimeTicks 是 100ns 单位，1 秒 = 10,000,000 ticks。
			DurationSeconds: item.RunTimeTicks / 10_000_000,
		})
	}

	snapshot, err := s.thumbs.Start(library.ID, library.Name, targets, intervalSeconds*1000, width)
	if errors.Is(err, media.ErrThumbnailJobRunning) {
		writeError(w, http.StatusConflict, "已有缩略图预生成任务在运行，请等待完成或先取消")
		return
	}
	if err != nil {
		// 例如 ffmpeg 路径无效：把原因原样交给前端，避免只显示"0 张"。
		log.Printf("启动缩略图预生成任务失败: %v", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	log.Printf("开始预生成缩略图: 媒体库=%s 条目=%d 间隔=%ds 宽度=%d",
		library.Name, len(targets), intervalSeconds, width)
	writeJSON(w, http.StatusOK, thumbnailJobToDto(snapshot))
}

// handleThumbnailJobs GET /ThumbnailJobs 返回最近的任务，最新的在前。
func (s *Server) handleThumbnailJobs(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	snapshots := s.thumbs.List()
	result := make([]thumbnailJobDto, 0, len(snapshots))
	for _, snapshot := range snapshots {
		result = append(result, thumbnailJobToDto(snapshot))
	}
	writeJSON(w, http.StatusOK, result)
}

// handleThumbnailJob GET /ThumbnailJobs/{jobId} 供前端轮询进度。
func (s *Server) handleThumbnailJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	snapshot, ok := s.thumbs.Snapshot(strings.TrimSpace(r.PathValue("jobId")))
	if !ok {
		writeError(w, http.StatusNotFound, "缩略图预生成任务不存在")
		return
	}
	writeJSON(w, http.StatusOK, thumbnailJobToDto(snapshot))
}

// handleCancelThumbnailJob POST /ThumbnailJobs/{jobId}/Cancel
func (s *Server) handleCancelThumbnailJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	snapshot, err := s.thumbs.Cancel(strings.TrimSpace(r.PathValue("jobId")))
	if errors.Is(err, media.ErrThumbnailJobNotFound) {
		writeError(w, http.StatusNotFound, "缩略图预生成任务不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "取消任务失败")
		return
	}
	log.Printf("已请求取消缩略图预生成任务: %s", snapshot.ID)
	writeJSON(w, http.StatusOK, thumbnailJobToDto(snapshot))
}
