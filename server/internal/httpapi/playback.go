package httpapi

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"embyx/internal/dto"
	"embyx/internal/store"
)

func (s *Server) handlePlaybackInfo(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")

	var payload dto.PlaybackInfoRequest
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload)
	userID := payload.UserID
	if userID == "" {
		if user := currentUser(r); user != nil {
			userID = user.ID
		}
	}

	item, err := s.store.GetItem(r.Context(), userID, itemID)
	if err != nil {
		writeError(w, http.StatusNotFound, "条目不存在")
		return
	}

	sources := item.MediaSources
	// 指定 MediaSourceId 时把它排到首位，客户端据此直接选中该版本。
	if payload.MediaSourceID != "" {
		for index, source := range sources {
			if source.ID == payload.MediaSourceID {
				sources[0], sources[index] = sources[index], sources[0]
				break
			}
		}
	}

	writeJSON(w, http.StatusOK, dto.PlaybackInfoResponse{
		MediaSources:  sources,
		PlaySessionID: store.NewID(),
	})
}

// handleStream 直接回源文件流。ServeContent 负责 Range / 206 / If-Modified-Since，
// 这是 mpv 能正常 seek 的前提。
func (s *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")

	// 只取路径：拖动进度条会产生密集的 Range 请求，
	// 没必要每次都扫 32 列并反序列化 11 个 JSON 字段。
	source, err := s.store.ItemSource(r.Context(), itemID)
	if err != nil || source.Path == "" {
		writeError(w, http.StatusNotFound, "媒体文件不存在")
		return
	}

	file, err := os.Open(source.Path)
	if err != nil {
		writeError(w, http.StatusNotFound, "媒体文件不可读")
		return
	}
	defer file.Close()

	stat, err := file.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "读取文件信息失败")
		return
	}

	if mime, ok := streamMimeTypes[strings.ToLower(filepath.Ext(source.Path))]; ok {
		w.Header().Set("Content-Type", mime)
	}
	w.Header().Set("Accept-Ranges", "bytes")

	http.ServeContent(w, r, filepath.Base(source.Path), stat.ModTime(), file)
}

func (s *Server) handleBif(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")
	source, err := s.store.ItemSource(r.Context(), itemID)
	if err != nil || source.Path == "" {
		writeError(w, http.StatusNotFound, "条目不存在")
		return
	}

	width := atoi(r.URL.Query().Get("Width"))
	bifPath, ready := s.bif.EnsureAsync(itemID, source.Path, bifIntervalParam(r), width)
	if !ready {
		// 首次播放不阻塞：后台抽帧，本次让播放器降级成普通进度条。
		// 前端拿到非 200 会直接不显示预览，不会报错。
		w.Header().Set("Retry-After", "30")
		w.WriteHeader(http.StatusAccepted)
		return
	}

	file, err := os.Open(bifPath)
	if err != nil {
		writeError(w, http.StatusNotFound, "缩略图不可用")
		return
	}
	defer file.Close()

	stat, err := file.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "读取缩略图信息失败")
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeContent(w, r, filepath.Base(bifPath), stat.ModTime(), file)
}

func (s *Server) handleSessionStarted(w http.ResponseWriter, r *http.Request) {
	s.recordPlayback(w, r, false)
}

func (s *Server) handleSessionProgress(w http.ResponseWriter, r *http.Request) {
	s.recordPlayback(w, r, false)
}

func (s *Server) handleSessionStopped(w http.ResponseWriter, r *http.Request) {
	s.recordPlayback(w, r, true)
}

// recordPlayback 统一处理三类上报：started / progress / stopped。
func (s *Server) recordPlayback(w http.ResponseWriter, r *http.Request, stopped bool) {
	var payload dto.PlaybackProgressInfo
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	userID := payload.UserID
	if userID == "" {
		if user := currentUser(r); user != nil {
			userID = user.ID
		}
	}
	if payload.ItemID == "" || userID == "" {
		writeError(w, http.StatusBadRequest, "缺少 ItemId 或 UserId")
		return
	}

	if err := s.store.SavePlaybackProgress(r.Context(), userID, payload.ItemID, payload.PositionTicks, stopped); err != nil {
		writeError(w, http.StatusInternalServerError, "保存播放进度失败")
		return
	}
	if payload.PlaySessionID != "" {
		_ = s.store.SavePlaySession(r.Context(), payload.PlaySessionID, userID, payload.ItemID, payload.PositionTicks)
	}
	writeNoContent(w)
}

// bifIntervalDefault 是播放侧使用的默认抽帧间隔（毫秒），与客户端的约定一致。
const bifIntervalDefault = 10000

// bifIntervalParam 读取 IntervalMs 参数：预生成用了别的间隔时，
// 播放侧传同样的值就能命中参数完全一致的文件，而不是退到任意变体。
func bifIntervalParam(r *http.Request) uint32 {
	query := r.URL.Query()
	value := atoi(firstNonEmpty(query.Get("IntervalMs"), query.Get("intervalMs")))
	if value <= 0 {
		return bifIntervalDefault
	}
	return uint32(value)
}

var streamMimeTypes = map[string]string{
	".mkv":  "video/x-matroska",
	".mp4":  "video/mp4",
	".m4v":  "video/mp4",
	".mov":  "video/quicktime",
	".avi":  "video/x-msvideo",
	".ts":   "video/mp2t",
	".m2ts": "video/mp2t",
	".webm": "video/webm",
	".flv":  "video/x-flv",
	".wmv":  "video/x-ms-wmv",
	".rmvb": "application/vnd.rn-realmedia-vbr",
}
