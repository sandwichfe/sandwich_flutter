package httpapi

import (
	"encoding/json"
	"io"
	"log"
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
	userID := ""
	if user := currentUser(r); user != nil {
		userID = user.ID
	}

	item, err := s.store.GetItem(r.Context(), userID, itemID)
	if err != nil || item.Path == "" {
		writeError(w, http.StatusNotFound, "媒体文件不存在")
		return
	}

	file, err := os.Open(item.Path)
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

	if mime, ok := streamMimeTypes[strings.ToLower(filepath.Ext(item.Path))]; ok {
		w.Header().Set("Content-Type", mime)
	}
	w.Header().Set("Accept-Ranges", "bytes")

	http.ServeContent(w, r, filepath.Base(item.Path), stat.ModTime(), file)
}

func (s *Server) handleBif(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")
	userID := ""
	if user := currentUser(r); user != nil {
		userID = user.ID
	}

	item, err := s.store.GetItem(r.Context(), userID, itemID)
	if err != nil || item.Path == "" {
		writeError(w, http.StatusNotFound, "条目不存在")
		return
	}

	width := atoi(r.URL.Query().Get("Width"))
	bifPath, err := s.bif.Ensure(r.Context(), itemID, item.Path, 10000, width)
	if err != nil {
		// 无法生成时返回 404，播放器会自动降级为普通进度条。
		log.Printf("生成 BIF 失败 item=%s: %v", itemID, err)
		writeError(w, http.StatusNotFound, "缩略图不可用")
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
