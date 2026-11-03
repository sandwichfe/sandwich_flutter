package httpapi

import (
	"errors"
	"net/http"
	"strings"

	"embyx/internal/dto"
	"embyx/internal/media"
)

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	itemID := r.PathValue("itemId")
	imageType := r.PathValue("type")
	index := atoi(r.PathValue("index"))

	raw, err := s.images.LoadItemImage(itemID, imageType, index)
	if err != nil {
		writeError(w, http.StatusNotFound, "图片不存在")
		return
	}

	maxWidth := atoi(firstNonEmpty(r.URL.Query().Get("maxWidth"), r.URL.Query().Get("MaxWidth")))
	quality := atoi(r.URL.Query().Get("quality"))
	rendered, err := media.Render(raw, maxWidth, quality)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "渲染图片失败")
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

	if err := s.images.DeleteItemImage(itemID, imageType, index); err != nil {
		if errors.Is(err, media.ErrImageNotFound) {
			writeError(w, http.StatusNotFound, "图片不存在")
			return
		}
		writeError(w, http.StatusInternalServerError, "删除图片失败")
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
		normalized := normalizeImageType(imageType)
		if tag == "" {
			delete(imageTags, normalized)
		} else {
			imageTags[normalized] = tag
		}
		return s.store.SetImageTags(r.Context(), itemID, "image_tags", imageTags)
	}
}

// normalizeImageType 对齐 Emby 的 ImageType 命名。
func normalizeImageType(value string) string {
	switch strings.ToLower(value) {
	case "primary":
		return "Primary"
	case "logo":
		return "Logo"
	case "thumb":
		return "Thumb"
	case "banner":
		return "Banner"
	case "disc":
		return "Disc"
	case "art":
		return "Art"
	case "chapter":
		return "Chapter"
	case "backdrop":
		return "Backdrop"
	case "screenshot":
		return "Screenshot"
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
