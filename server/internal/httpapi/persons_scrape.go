package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"

	"embyx/internal/metadata"
	"embyx/internal/store"
)

// personScrapeJobDto 是设置页/人物页轮询的刮削任务状态。
// 字段为本项目扩展（不属于 Emby 协议），命名保持 PascalCase 便于前端直接读取。
type personScrapeJobDto struct {
	JobId string `json:"JobId"`
	// Mode 取值 all / missing / single。
	Mode  string `json:"Mode"`
	Force bool   `json:"Force"`
	Total int    `json:"Total"`
	// Completed 是成功匹配的人次，Skipped 是重名待确认或没找到。
	Completed   int      `json:"Completed"`
	Failed      int      `json:"Failed"`
	Skipped     int      `json:"Skipped"`
	Updated     int      `json:"Updated"`
	Images      int      `json:"Images"`
	Progress    float64  `json:"Progress"`
	Status      string   `json:"Status"`
	CurrentItem string   `json:"CurrentItem"`
	Errors      []string `json:"Errors"`
	StartedAt   string   `json:"StartedAt"`
	FinishedAt  string   `json:"FinishedAt"`
}

func personScrapeJobToDto(snapshot metadata.PersonScrapeJobSnapshot) personScrapeJobDto {
	messages := snapshot.Errors
	if messages == nil {
		messages = []string{}
	}
	return personScrapeJobDto{
		JobId:       snapshot.ID,
		Mode:        snapshot.Mode,
		Force:       snapshot.Force,
		Total:       snapshot.Total,
		Completed:   snapshot.Completed,
		Failed:      snapshot.Failed,
		Skipped:     snapshot.Skipped,
		Updated:     snapshot.Updated,
		Images:      snapshot.Images,
		Progress:    snapshot.Progress(),
		Status:      snapshot.Status,
		CurrentItem: snapshot.CurrentItem,
		Errors:      messages,
		StartedAt:   snapshot.StartedAt,
		FinishedAt:  snapshot.FinishedAt,
	}
}

// personScrapeJobsDto 同时告诉前端「有没有配置 API Key」，
// 否则没配 Key 时列表永远是空的，用户不知道是没任务还是没启用。
type personScrapeJobsDto struct {
	Configured bool                 `json:"Configured"`
	Jobs       []personScrapeJobDto `json:"Jobs"`
}

// handleCreatePersonScrapeJob POST /emby/PersonScrapeJobs
// 正文：{ "Mode": "all" | "missing", "Force": false }
// Mode=missing 只处理还没有 Tmdb 编号或从未刮削过的演员，适合日常增量刷新。
func (s *Server) handleCreatePersonScrapeJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	if s.personScrape == nil {
		writeError(w, http.StatusBadRequest, "演员刮削未启用，请在 config.yaml 配置 tmdb.api_key 或开启 jav.enabled")
		return
	}

	var payload struct {
		Mode  string `json:"Mode"`
		Force bool   `json:"Force"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	onlyMissing := !strings.EqualFold(strings.TrimSpace(payload.Mode), "all")
	mode := "all"
	if onlyMissing {
		mode = "missing"
	}

	targets, err := s.store.PersonScrapeTargets(r.Context(), onlyMissing)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "读取待刮削演员失败")
		return
	}
	if len(targets) == 0 {
		writeError(w, http.StatusBadRequest, "没有需要刮削的演员，请先扫描媒体库")
		return
	}

	snapshot, err := s.personScrape.Start(targets, payload.Force, mode)
	if errors.Is(err, metadata.ErrPersonScrapeRunning) {
		writeError(w, http.StatusConflict, "已有演员刮削任务在运行，请等待完成或先取消")
		return
	}
	if err != nil {
		log.Printf("启动演员刮削任务失败: %v", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	log.Printf("开始刮削演员: 范围=%s 人数=%d 覆盖=%v", mode, len(targets), payload.Force)
	writeJSON(w, http.StatusOK, personScrapeJobToDto(snapshot))
}

// handlePersonScrapeJobs GET /emby/PersonScrapeJobs 返回最近任务，最新的在前。
func (s *Server) handlePersonScrapeJobs(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	response := personScrapeJobsDto{Jobs: []personScrapeJobDto{}}
	if s.personScrape == nil {
		writeJSON(w, http.StatusOK, response)
		return
	}
	response.Configured = true
	for _, snapshot := range s.personScrape.List() {
		response.Jobs = append(response.Jobs, personScrapeJobToDto(snapshot))
	}
	writeJSON(w, http.StatusOK, response)
}

// handlePersonScrapeJob GET /emby/PersonScrapeJobs/{jobId} 供前端轮询进度。
func (s *Server) handlePersonScrapeJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	if s.personScrape == nil {
		writeError(w, http.StatusBadRequest, "演员刮削未启用，请在 config.yaml 配置 tmdb.api_key 或开启 jav.enabled")
		return
	}
	snapshot, ok := s.personScrape.Snapshot(strings.TrimSpace(r.PathValue("jobId")))
	if !ok {
		writeError(w, http.StatusNotFound, "演员刮削任务不存在")
		return
	}
	writeJSON(w, http.StatusOK, personScrapeJobToDto(snapshot))
}

// handleCancelPersonScrapeJob POST /emby/PersonScrapeJobs/{jobId}/Cancel
func (s *Server) handleCancelPersonScrapeJob(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	if s.personScrape == nil {
		writeError(w, http.StatusBadRequest, "演员刮削未启用，请在 config.yaml 配置 tmdb.api_key 或开启 jav.enabled")
		return
	}
	snapshot, err := s.personScrape.Cancel(strings.TrimSpace(r.PathValue("jobId")))
	if errors.Is(err, metadata.ErrPersonScrapeNotFound) {
		writeError(w, http.StatusNotFound, "演员刮削任务不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "取消任务失败")
		return
	}
	writeJSON(w, http.StatusOK, personScrapeJobToDto(snapshot))
}

// handleScrapePerson POST /emby/Persons/{personId}/Scrape
// 正文可选：{ "Force": true }。单个刮削同样排进队列，避免与批量任务抢占限流。
func (s *Server) handleScrapePerson(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	if s.personScrape == nil {
		writeError(w, http.StatusBadRequest, "演员刮削未启用，请在 config.yaml 配置 tmdb.api_key 或开启 jav.enabled")
		return
	}

	var payload struct {
		Force bool `json:"Force"`
	}
	// 正文可以为空（前端直接 POST），只有存在内容时才解析。
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	personID := strings.TrimSpace(r.PathValue("personId"))
	target, err := s.store.PersonScrapeTargetByID(r.Context(), personID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "演员不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "读取演员信息失败")
		return
	}

	snapshot, err := s.personScrape.Start([]store.PersonScrapeTarget{*target}, payload.Force, "single")
	if errors.Is(err, metadata.ErrPersonScrapeRunning) {
		writeError(w, http.StatusConflict, "已有演员刮削任务在运行，请等待完成或先取消")
		return
	}
	if err != nil {
		log.Printf("启动单人刮削失败: %v", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	log.Printf("开始刮削演员: %s（%s）覆盖=%v", target.Name, target.ID, payload.Force)
	writeJSON(w, http.StatusOK, personScrapeJobToDto(snapshot))
}
