package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"embyx/internal/dto"
	"embyx/internal/media"
	"embyx/internal/store"
)

// 图片来源标记，前端据此区分目录图与服务端生成图。
const (
	imageSourceLocal     = "local"
	imageSourceGenerated = "generated"
)

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")
	imageType := r.PathValue("type")
	index := atoi(r.PathValue("index"))

	raw, err := s.loadItemImage(r, itemID, imageType, index)
	if err != nil {
		writeError(w, http.StatusNotFound, "图片不存在")
		return
	}

	// 参数先归一化，保证 ETag 与缓存 key 用的是同一组值。
	maxWidth := media.NormalizeRenderWidth(atoi(firstNonEmpty(r.URL.Query().Get("maxWidth"), r.URL.Query().Get("MaxWidth"))))
	quality := media.NormalizeRenderQuality(atoi(r.URL.Query().Get("quality")))

	rendered, tag, err := s.imageRenderer.Render(itemID, imageType, index, raw, maxWidth, quality)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "渲染图片失败")
		return
	}

	// ETag 由源图内容与缩放参数组成：换图、换尺寸都会变，客户端不会拿到旧图。
	etag := fmt.Sprintf(`"%s-w%d-q%d"`, tag, maxWidth, quality)
	w.Header().Set("ETag", etag)
	if match := r.Header.Get("If-None-Match"); match != "" && match == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}

	w.Header().Set("Content-Type", "image/jpeg")
	// 客户端用 v= 参数打破缓存，这里直接长缓存即可。
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write(rendered)
}

func (s *Server) handleListImages(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")
	files, err := s.images.ListItemImages(itemID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "读取图片列表失败")
		return
	}
	// 生成图与目录图分开存放，但都算这个条目的图片，一起返回给编辑弹窗。
	generated, err := s.images.ListGeneratedImages(itemID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "读取图片列表失败")
		return
	}

	result := make([]dto.ImageInfo, 0, len(files)+len(generated))
	for _, file := range files {
		result = append(result, dto.ImageInfo{
			ImageType:  file.Type,
			ImageIndex: file.Index,
			Filename:   file.Filename,
			Size:       file.Size,
			Source:     imageSourceLocal,
		})
	}
	for _, file := range generated {
		result = append(result, dto.ImageInfo{
			ImageType:  file.Type,
			ImageIndex: file.Index,
			Filename:   file.Filename,
			Size:       file.Size,
			Source:     imageSourceGenerated,
		})
	}
	writeJSON(w, http.StatusOK, result)
}

// loadItemImage 决定优先读目录图还是服务端生成图。
// 两种图互相兜底：优先的那种不存在时自动回退另一种，避免列表出现空白。
func (s *Server) loadItemImage(r *http.Request, itemID, imageType string, index int) ([]byte, error) {
	if s.preferGeneratedArtwork(r, itemID) {
		raw, err := s.images.LoadGeneratedImage(itemID, imageType, index)
		if errors.Is(err, media.ErrImageNotFound) {
			s.logArtworkPick(r, "generated 缺失→回退 local", s.images.ItemPath(itemID, imageType, index))
			return s.images.LoadItemImage(itemID, imageType, index)
		}
		s.logArtworkPick(r, "generated", s.images.GeneratedPath(itemID, imageType, index))
		return raw, err
	}
	raw, err := s.images.LoadItemImage(itemID, imageType, index)
	if errors.Is(err, media.ErrImageNotFound) {
		s.logArtworkPick(r, "local 缺失→回退 generated", s.images.GeneratedPath(itemID, imageType, index))
		return s.images.LoadGeneratedImage(itemID, imageType, index)
	}
	s.logArtworkPick(r, "local", s.images.ItemPath(itemID, imageType, index))
	return raw, err
}

// logArtworkPick 打印客户端这次实际读到的图片文件，用于确认界面显示的是目录图还是生成图。
// 只在 URL 带 debugArtwork=1 时输出，避免每个图片请求都刷日志。
func (s *Server) logArtworkPick(r *http.Request, source string, path string) {
	if r.URL.Query().Get("debugArtwork") == "" {
		return
	}
	log.Printf("[image] 读取=%s 文件=%q", source, path)
}

// preferGeneratedArtwork 的优先级：显式 Source 参数（图像编辑弹窗预览用）>
// 条目所属媒体库的封面来源偏好（设置页按库配置）> 默认读取目录图。
func (s *Server) preferGeneratedArtwork(r *http.Request, itemID string) bool {
	switch artworkSourceParam(r) {
	case imageSourceGenerated:
		return true
	case imageSourceLocal:
		return false
	}
	return !s.store.ItemPreferLocalArtwork(r.Context(), itemID)
}

// artworkSourceParam 读取 Source 参数，兼容 camelCase / PascalCase 写法。
func artworkSourceParam(r *http.Request) string {
	query := r.URL.Query()
	value := strings.ToLower(strings.TrimSpace(firstNonEmpty(
		query.Get("Source"), query.Get("source"), query.Get("ArtworkSource"),
	)))
	if value == imageSourceGenerated || value == imageSourceLocal {
		return value
	}
	return ""
}

func (s *Server) handleUploadImage(w http.ResponseWriter, r *http.Request) {
	user := currentUser(r)
	if user == nil || !user.IsAdmin {
		writeError(w, http.StatusForbidden, "需要管理员权限")
		return
	}

	itemID := r.PathValue("itemId")
	imageType := r.PathValue("type")
	index := atoi(r.PathValue("index"))

	raw, err := readImageBody(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	tag, err := s.images.SaveItemImage(itemID, imageType, index, raw)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "保存图片失败")
		return
	}
	// 换了图就丢掉旧的缩放缓存，避免磁盘上堆积再也用不到的文件。
	s.imageRenderer.RemoveItem(itemID)
	if err := s.syncImageTags(r, itemID, imageType, index, tag); err != nil {
		writeError(w, http.StatusInternalServerError, "更新图片标记失败")
		return
	}
	writeNoContent(w)
}

func (s *Server) handleDeleteImage(w http.ResponseWriter, r *http.Request) {
	user := currentUser(r)
	if user == nil || !user.IsAdmin {
		writeError(w, http.StatusForbidden, "需要管理员权限")
		return
	}

	itemID := r.PathValue("itemId")
	imageType := r.PathValue("type")
	index := atoi(r.PathValue("index"))

	// 编辑弹窗里生成图带 Source=generated，删除时必须落到对应的目录。
	if artworkSourceParam(r) == imageSourceGenerated {
		if err := s.images.DeleteGeneratedImage(itemID, imageType, index); err != nil {
			if errors.Is(err, media.ErrImageNotFound) {
				writeError(w, http.StatusNotFound, "图片不存在")
				return
			}
			writeError(w, http.StatusInternalServerError, "删除图片失败")
			return
		}
		s.imageRenderer.RemoveItem(itemID)
		// 目录图还在时 tag 继续有效；否则清空标记，客户端回退到占位图。
		if _, loadErr := s.images.LoadItemImage(itemID, imageType, index); loadErr != nil {
			_ = s.syncImageTags(r, itemID, imageType, index, "")
		}
		writeNoContent(w)
		return
	}

	if err := s.images.DeleteItemImage(itemID, imageType, index); err != nil {
		if errors.Is(err, media.ErrImageNotFound) {
			writeError(w, http.StatusNotFound, "图片不存在")
			return
		}
		writeError(w, http.StatusInternalServerError, "删除图片失败")
		return
	}
	s.imageRenderer.RemoveItem(itemID)
	if err := s.syncImageTags(r, itemID, imageType, index, ""); err != nil {
		writeError(w, http.StatusInternalServerError, "更新图片标记失败")
		return
	}
	writeNoContent(w)
}

// syncImageTags 把落盘结果同步回条目的 ImageTags / BackdropImageTags，
// 客户端靠这些标记决定是否发起图片请求。
func (s *Server) syncImageTags(r *http.Request, itemID, imageType string, index int, tag string) error {
	item, err := s.store.GetItem(r.Context(), currentUser(r).ID, itemID)
	if err != nil {
		return err
	}

	switch strings.ToLower(imageType) {
	case "backdrop":
		tags := append([]string(nil), item.BackdropImageTags...)
		for len(tags) <= index {
			tags = append(tags, "")
		}
		tags[index] = tag
		return s.store.SetImageTags(r.Context(), itemID, "backdrop_tags", tags)
	case "screenshot":
		tags := append([]string(nil), item.ScreenshotImageTags...)
		for len(tags) <= index {
			tags = append(tags, "")
		}
		tags[index] = tag
		return s.store.SetImageTags(r.Context(), itemID, "screenshot_tags", tags)
	default:
		imageTags := map[string]string{}
		for key, value := range item.ImageTags {
			imageTags[key] = value
		}
		// 与生成器共用同一份类型映射；未知类型保留原值，避免写库时丢信息。
		normalized := media.NormalizeImageType(imageType)
		if normalized == "" {
			normalized = imageType
		}
		if tag == "" {
			delete(imageTags, normalized)
		} else {
			imageTags[normalized] = tag
		}
		return s.store.SetImageTags(r.Context(), itemID, "image_tags", imageTags)
	}
}

// handleGenerateArtwork 从视频画面生成海报 / 封面 / 缩略图。
// POST /emby/Items/{itemId}/Images/Generate
// 正文：{ "Types": ["Primary","Backdrop"], "PositionTicks": 0, "Width": 0 }
// PositionTicks 为 0 表示自动嗅探一帧；大于 0 时按该进度点取帧。
func (s *Server) handleGenerateArtwork(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	itemID := strings.TrimSpace(r.PathValue("itemId"))

	var payload struct {
		Types         []string `json:"Types"`
		PositionTicks int64    `json:"PositionTicks"`
		Width         int      `json:"Width"`
	}
	// 允许空正文：不传参数时按默认（海报 + 封面，自动嗅探）执行。
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	source, err := s.store.ItemSource(r.Context(), itemID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "条目不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询条目失败")
		return
	}

	// 单条目抽帧通常几秒内完成，超时上限只用于兜住异常片源。
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()

	result, err := s.artwork.Generate(ctx, itemID, media.ArtworkOptions{
		SourcePath:    source.Path,
		RunTimeTicks:  source.RunTimeTicks,
		PositionTicks: payload.PositionTicks,
		Types:         payload.Types,
		Width:         payload.Width,
	})
	if err != nil {
		log.Printf("生成封面失败 item=%s name=%s: %v", itemID, source.Name, err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	s.markGeneratedImageTags(itemID, result.Tags)
	log.Printf("生成封面完成 item=%s name=%s 类型=%v 位置=%.3fs 嗅探=%v",
		itemID, source.Name, payload.Types, float64(result.PositionTicks)/10_000_000, result.Sniffed)

	writeJSON(w, http.StatusOK, map[string]any{
		"ItemId":        itemID,
		"PositionTicks": result.PositionTicks,
		"Sniffed":       result.Sniffed,
		"Tags":          result.Tags,
	})
}

// markGeneratedImageTags 在目录里没有对应图片时回写 tag。
// 客户端靠 ImageTags 决定是否发起图片请求，不回写的话生成图根本不会被加载。
// 批量任务在后台 goroutine 里调用，因此不依赖请求上下文。
func (s *Server) markGeneratedImageTags(itemID string, tags map[string]string) {
	for imageType, tag := range tags {
		if err := s.store.EnsureImageTag(context.Background(), itemID, imageType, tag); err != nil {
			log.Printf("回写图片标记失败 item=%s type=%s: %v", itemID, imageType, err)
		}
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
