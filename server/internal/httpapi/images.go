package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"embyx/internal/dto"
	"embyx/internal/media"
	"embyx/internal/store"
)

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")
	imageType := r.PathValue("type")
	index := atoi(r.PathValue("index"))

	// 一个槽位只有一张图：文件在就返回，不在就是 404，没有来源回退。
	if r.URL.Query().Get("debugArtwork") != "" {
		log.Printf("[image] 读取 item=%s 类型=%s 序号=%d 文件=%q",
			itemID, imageType, index, s.images.ItemPath(itemID, imageType, index))
	}

	raw, err := s.images.LoadItemImage(itemID, imageType, index)
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
	// 一个槽位一张图，磁盘上有什么就返回什么，弹窗不再需要区分来源。
	result := make([]dto.ImageInfo, 0, len(files))
	for _, file := range files {
		result = append(result, dto.ImageInfo{
			ImageType:  file.Type,
			ImageIndex: file.Index,
			Filename:   file.Filename,
			Size:       file.Size,
		})
	}
	writeJSON(w, http.StatusOK, result)
}

// handleImageLock GET /emby/Items/{itemId}/Images/Lock
// 读取图片锁状态：锁定后扫描导入、扫描结束的自动重拼都不会覆盖现有图片。
func (s *Server) handleImageLock(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{
		"Locked": s.images.ItemLocked(r.PathValue("itemId")),
	})
}

// handleSetImageLock POST /emby/Items/{itemId}/Images/Lock
// 正文 {"Locked":true}，也接受 ?locked=true，方便脚本调用。
// 锁只挡自动流程，手动上传、生成、删除仍然允许。
func (s *Server) handleSetImageLock(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}

	var payload struct {
		Locked *bool `json:"Locked"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	locked := payload.Locked
	if locked == nil {
		value := strings.TrimSpace(firstNonEmpty(r.URL.Query().Get("locked"), r.URL.Query().Get("Locked")))
		if value == "" {
			writeError(w, http.StatusBadRequest, "缺少 locked 参数")
			return
		}
		parsed := strings.EqualFold(value, "true")
		locked = &parsed
	}

	if err := s.images.SetItemLocked(r.PathValue("itemId"), *locked); err != nil {
		log.Printf("[image] 更新图片锁失败 item=%s: %v", r.PathValue("itemId"), err)
		writeError(w, http.StatusInternalServerError, "更新图片锁失败")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"Locked": *locked})
}

// handleFramePreview GET /emby/Items/{itemId}/Images/Frame?PositionTicks=&MaxWidth=
// 编辑弹窗里拖动取帧滑块时的实时预览：按进度点抽一帧直接返回，
// 不落盘、不写图片标记，所以反复预览不会影响已有海报和封面。
func (s *Server) handleFramePreview(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")
	ticks, err := strconv.ParseInt(strings.TrimSpace(firstNonEmpty(
		r.URL.Query().Get("PositionTicks"), r.URL.Query().Get("positionTicks"),
	)), 10, 64)
	if err != nil || ticks < 0 {
		writeError(w, http.StatusBadRequest, "取帧位置不合法")
		return
	}

	// 预览只需要看得清，宽度上限压到 960，避免每次抽帧都解一张大图。
	width := media.NormalizeRenderWidth(atoi(firstNonEmpty(
		r.URL.Query().Get("MaxWidth"), r.URL.Query().Get("maxWidth"),
	)))
	if width <= 0 || width > 960 {
		width = 640
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
	if source.Path == "" {
		writeError(w, http.StatusBadRequest, "该条目没有可用的视频文件")
		return
	}

	// 单帧解码通常在几百毫秒，超时上限只用于兜住异常片源。
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	positionSeconds := float64(ticks) / 10_000_000
	raw, err := s.artwork.PreviewFrame(ctx, source.Path, positionSeconds, width)
	if err != nil {
		log.Printf("[artwork] 预览取帧失败 item=%s 位置=%.3fs: %v", itemID, positionSeconds, err)
		writeError(w, http.StatusInternalServerError, "截取画面失败")
		return
	}

	w.Header().Set("Content-Type", "image/jpeg")
	// 同一进度点的画面不会变，来回拖动可以直接命中缓存。
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(raw)
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
	// 记住这张是用户上传的：扫描导入目录图时不会把它覆盖掉。
	if err := s.images.WriteOrigin(itemID, imageType, index, media.OriginUpload); err != nil {
		log.Printf("[image] 写入图片来源失败 item=%s type=%s: %v", itemID, imageType, err)
	}
	if err := s.syncImageTags(r, itemID, imageType, index, tag); err != nil {
		writeError(w, http.StatusInternalServerError, "更新图片标记失败")
		return
	}
	// 上传了新的手动封面，解除"用户删过封面"的状态，拼图恢复兜底资格。
	if s.libraryCovers != nil {
		if _, libErr := s.store.LibraryByID(r.Context(), itemID); libErr == nil {
			if err := s.libraryCovers.ClearCoverDeleted(itemID); err != nil {
				log.Printf("[library-cover] 清除媒体库封面删除标记失败 library=%s: %v", itemID, err)
			}
		}
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

	// 媒体库不在 items 表里，封面标记由封面文件自己维护，
	// 走 syncImageTags 回写 items 必然拿不到条目而报 500。
	_, libErr := s.store.LibraryByID(r.Context(), itemID)
	isLibrary := libErr == nil && s.libraryCovers != nil

	if err := s.images.DeleteItemImage(itemID, imageType, index); err != nil {
		if errors.Is(err, media.ErrImageNotFound) {
			writeError(w, http.StatusNotFound, "图片不存在")
			return
		}
		writeError(w, http.StatusInternalServerError, "删除图片失败")
		return
	}
	s.imageRenderer.RemoveItem(itemID)
	// 清掉来源标记：否则扫描会以为这里仍是用户设置过的图而跳过重新导入。
	if err := s.images.RemoveOrigin(itemID, imageType, index); err != nil {
		log.Printf("[image] 清理图片来源失败 item=%s type=%s: %v", itemID, imageType, err)
	}
	if isLibrary {
		// 用户要自己传封面或显式重拼，这里不再自动拼回来。
		if err := s.libraryCovers.ForgetGeneratedCover(itemID); err != nil {
			log.Printf("[library-cover] 清理媒体库封面失败 library=%s: %v", itemID, err)
		}
		if err := s.libraryCovers.MarkCoverDeleted(itemID); err != nil {
			writeError(w, http.StatusInternalServerError, "删除图片失败")
			return
		}
		writeNoContent(w)
		return
	}
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
	if errors.Is(err, store.ErrNotFound) {
		// 媒体库、人物等实体不在 items 表里，没有可回写的标记，视为成功。
		return nil
	}
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
		// 删掉最后一张时把尾部空位裁掉，避免客户端看到一个空 tag 还去请求图片。
		for len(tags) > 0 && tags[len(tags)-1] == "" {
			tags = tags[:len(tags)-1]
		}
		return s.store.SetImageTags(r.Context(), itemID, "backdrop_tags", tags)
	case "screenshot":
		tags := append([]string(nil), item.ScreenshotImageTags...)
		for len(tags) <= index {
			tags = append(tags, "")
		}
		tags[index] = tag
		for len(tags) > 0 && tags[len(tags)-1] == "" {
			tags = tags[:len(tags)-1]
		}
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

// markGeneratedImageTags 把生成结果回写到条目的图片标记。
// 一个槽位只有一张图，生成就是覆盖它：标记必须一起更新，
// 否则客户端 URL 里的 v 不变，会一直命中旧缓存看不到新图。
// 批量任务在后台 goroutine 里调用，因此不依赖请求上下文。
func (s *Server) markGeneratedImageTags(itemID string, tags map[string]string) {
	for imageType, tag := range tags {
		if err := s.store.ReplaceImageTag(context.Background(), itemID, imageType, tag); err != nil {
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
