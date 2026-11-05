package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"

	"embyx/internal/dto"
	"embyx/internal/media"
	"embyx/internal/store"
)

// virtualFolderDto 对齐 Emby/Jellyfin 的 VirtualFolderInfo。
// ItemCount 是本项目扩展字段，设置页用来显示库内条目数。
type virtualFolderDto struct {
	Name           string   `json:"Name"`
	Locations      []string `json:"Locations"`
	CollectionType string   `json:"CollectionType,omitempty"`
	ItemId         string   `json:"ItemId,omitempty"`
	ItemCount      int      `json:"ItemCount"`
	// PreferLocalArtwork 为本库的封面来源偏好：true 扫描时导入目录图，
	// false 不导入、直接使用生成图。图片本身只存一份，切换不会丢已有封面。
	PreferLocalArtwork bool `json:"PreferLocalArtwork"`
}

// libraryToDto 把媒体库包装成客户端视图条目。
// 只有带上 Primary 标记，客户端才会去请求库封面，否则一律按无图处理。
func (s *Server) libraryToDto(lib store.Library) dto.BaseItemDto {
	locations := lib.Paths
	if locations == nil {
		locations = []string{}
	}
	// 手动/目录封面优先，其次才是拼图封面，规则与读图链路一致。
	imageTags := map[string]string{}
	if s.libraryCovers != nil {
		if tag := s.libraryCovers.Tag(lib.ID); tag != "" {
			imageTags["Primary"] = tag
		}
	}
	return dto.BaseItemDto{
		ID:             lib.ID,
		Name:           lib.Name,
		Type:           "CollectionFolder",
		CollectionType: lib.CollectionType,
		IsFolder:       true,
		Locations:      locations,
		ImageTags:      imageTags,
		// 客户端优先用 PrimaryImageTag 做缓存键，两个字段保持一致。
		PrimaryImageTag: imageTags["Primary"],
	}
}

// handleViews 对应客户端 GET /Users/{id}/Views。
func (s *Server) handleViews(w http.ResponseWriter, r *http.Request) {
	libraries, err := s.store.Libraries(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}

	items := make([]dto.BaseItemDto, 0, len(libraries))
	for _, lib := range libraries {
		items = append(items, s.libraryToDto(lib))
	}
	writeJSON(w, http.StatusOK, dto.QueryResult{Items: items, TotalRecordCount: len(items)})
}

// handleListVirtualFolders GET /Library/VirtualFolders
func (s *Server) handleListVirtualFolders(w http.ResponseWriter, r *http.Request) {
	libraries, err := s.store.Libraries(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}

	// 一次聚合查出全部库的条目数，避免每个库各发一条 COUNT。
	counts, err := s.store.CountItemsByLibrary(r.Context())
	if err != nil {
		log.Printf("统计媒体库条目数失败: %v", err)
		counts = map[string]int{}
	}

	result := make([]virtualFolderDto, 0, len(libraries))
	for _, lib := range libraries {
		result = append(result, virtualFolderDto{
			Name:               lib.Name,
			Locations:          lib.Paths,
			CollectionType:     lib.CollectionType,
			ItemId:             lib.ID,
			ItemCount:          counts[lib.ID],
			PreferLocalArtwork: lib.PreferLocalArtwork,
		})
	}
	writeJSON(w, http.StatusOK, result)
}

// handleCreateVirtualFolder POST /Library/VirtualFolders
// 参数 name / collectionType / paths（可重复）/ refreshLibrary。
// name 已存在时视为更新，方便客户端用一个入口完成新建与保存。
func (s *Server) handleCreateVirtualFolder(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	params := r.URL.Query()

	name := strings.TrimSpace(params.Get("name"))
	if name == "" {
		writeError(w, http.StatusBadRequest, "缺少参数 name")
		return
	}
	paths := parsePaths(params)

	lib, err := s.store.LibraryByName(r.Context(), name)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}
	if lib == nil {
		// 新建默认读取目录内的海报/封面，保持与升级前一致的表现。
		lib = &store.Library{Name: name, CollectionType: "movies", PreferLocalArtwork: true}
	}

	if collectionType := strings.TrimSpace(params.Get("collectionType")); collectionType != "" {
		lib.CollectionType = collectionType
	}
	if paths != nil {
		lib.Paths = paths
	}
	if value := strings.TrimSpace(params.Get("preferLocalArtwork")); value != "" {
		lib.PreferLocalArtwork = strings.EqualFold(value, "true")
	}
	if len(lib.Paths) == 0 {
		writeError(w, http.StatusBadRequest, "至少需要一个 paths 参数")
		return
	}

	if err := s.store.SaveLibrary(r.Context(), *lib); err != nil {
		if errors.Is(err, store.ErrDuplicateName) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "保存媒体库失败")
		return
	}

	// 新建时 ID 由存储层生成，需要回读一次才能拿到真实 ID 交给扫描。
	saved, err := s.store.LibraryByName(r.Context(), lib.Name)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "保存媒体库失败")
		return
	}

	if strings.EqualFold(params.Get("refreshLibrary"), "true") {
		s.scanLibraryAsync(saved)
	}
	writeNoContent(w)
}

// handleUpdateVirtualFolder PUT /Library/VirtualFolders/{libraryId}
// 设置页编辑用：一次提交名称、类型与目录。
func (s *Server) handleUpdateVirtualFolder(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}

	lib, err := s.store.LibraryByID(r.Context(), r.PathValue("libraryId"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "媒体库不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}

	var payload struct {
		Name           string   `json:"Name"`
		CollectionType string   `json:"CollectionType"`
		Paths          []string `json:"Paths"`
		// 用指针区分"没传"和"显式关掉"，只切换封面来源时不必回传其它字段。
		PreferLocalArtwork *bool `json:"PreferLocalArtwork"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}

	if name := strings.TrimSpace(payload.Name); name != "" {
		lib.Name = name
	}
	if collectionType := strings.TrimSpace(payload.CollectionType); collectionType != "" {
		lib.CollectionType = collectionType
	}
	if payload.Paths != nil {
		lib.Paths = normalizePathList(payload.Paths)
	}
	if payload.PreferLocalArtwork != nil {
		lib.PreferLocalArtwork = *payload.PreferLocalArtwork
	}
	if len(lib.Paths) == 0 {
		writeError(w, http.StatusBadRequest, "至少需要一个目录")
		return
	}

	if err := s.store.SaveLibrary(r.Context(), *lib); err != nil {
		if errors.Is(err, store.ErrDuplicateName) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "保存媒体库失败")
		return
	}
	writeNoContent(w)
}

// handleRefreshLibraryCover POST /Library/VirtualFolders/{libraryId}/RefreshCover
// 管理页"刷新媒体库图片"用：忽略签名强制重拼库封面，返回是否真的重写了图片。
// 拼图只有解码和 JPEG 编码，耗时在几十毫秒量级，直接同步执行，客户端可用返回值提示结果。
func (s *Server) handleRefreshLibraryCover(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	lib, err := s.store.LibraryByID(r.Context(), r.PathValue("libraryId"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "媒体库不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}
	if s.libraryCovers == nil {
		writeError(w, http.StatusServiceUnavailable, "当前服务器未启用媒体库封面生成")
		return
	}

	updated, err := s.libraryCovers.RebuildForce(r.Context(), *lib)
	if err != nil {
		log.Printf("[library-cover] 手动刷新媒体库封面失败 library=%s: %v", lib.ID, err)
		writeError(w, http.StatusInternalServerError, "刷新媒体库图片失败")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"Updated": updated})
}

// handleRenameVirtualFolder POST /Library/VirtualFolders/Name?name=&newName=
func (s *Server) handleRenameVirtualFolder(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	params := r.URL.Query()
	name := strings.TrimSpace(params.Get("name"))
	newName := strings.TrimSpace(params.Get("newName"))
	if name == "" || newName == "" {
		writeError(w, http.StatusBadRequest, "缺少参数 name 或 newName")
		return
	}

	lib, err := s.store.LibraryByName(r.Context(), name)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "媒体库不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return
	}

	lib.Name = newName
	if err := s.store.SaveLibrary(r.Context(), *lib); err != nil {
		if errors.Is(err, store.ErrDuplicateName) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "重命名媒体库失败")
		return
	}
	writeNoContent(w)
}

// handleDeleteVirtualFolder DELETE /Library/VirtualFolders?name=xxx 或 ?id=xxx
func (s *Server) handleDeleteVirtualFolder(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	lib := s.lookupLibrary(w, r)
	if lib == nil {
		return
	}

	itemIDs, err := s.store.DeleteLibrary(r.Context(), lib.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "删除媒体库失败")
		return
	}
	for _, itemID := range itemIDs {
		_ = s.images.RemoveItem(itemID)
		s.imageRenderer.RemoveItem(itemID)
	}
	// BIF 缓存也要一起回收：只靠每 6 小时的巡检，几千条的库会白占磁盘很久。
	// 批量方法只枚举一次目录，不会因为条目多而退化。
	if s.bif != nil {
		s.bif.RemoveItems(itemIDs)
	}
	// 库自身也有一份拼图封面（images/{libraryID}/generated），删除库时一并回收。
	_ = s.images.RemoveItem(lib.ID)
	s.imageRenderer.RemoveItem(lib.ID)
	log.Printf("已删除媒体库 %s，同时清理 %d 个条目", lib.Name, len(itemIDs))
	writeNoContent(w)
}

// handleLibraryRefresh POST /Library/Refresh 扫描全部媒体库。
func (s *Server) handleLibraryRefresh(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	media.RunSafe("媒体库全量扫描", func() {
		if _, err := s.scanner.ScanAll(s.baseContext(), log.Printf); err != nil {
			log.Printf("媒体库扫描失败: %v", err)
		}
	})
	writeNoContent(w)
}

func (s *Server) scanLibraryAsync(lib *store.Library) {
	target := *lib
	media.RunSafe("扫描媒体库 "+target.Name, func() {
		if _, err := s.scanner.ScanLibrary(s.baseContext(), target, log.Printf); err != nil {
			log.Printf("媒体库 %s 扫描失败: %v", target.Name, err)
		}
	})
}

// rebuildLibraryCovers 在扫描结束后重建拼图封面。
// 串行执行：多个库同时拼接会重复争抢 CPU 与磁盘，而这里不在请求路径上，排队没有副作用。
// 是否真的重拼由签名决定，所以"每次扫描都调用"不会产生多余的文件写入。
func (s *Server) rebuildLibraryCovers(libraryIDs []string) {
	if s.libraryCovers == nil || len(libraryIDs) == 0 {
		return
	}
	media.RunSafe("重建媒体库封面", func() {
		ctx := s.baseContext()
		for _, id := range libraryIDs {
			lib, err := s.store.LibraryByID(ctx, id)
			if err != nil {
				continue
			}
			updated, err := s.libraryCovers.Rebuild(ctx, *lib)
			if err != nil {
				log.Printf("[library-cover] 生成媒体库封面失败 library=%s: %v", id, err)
				continue
			}
			if updated {
				log.Printf("[library-cover] 已更新媒体库封面 library=%s (%s)", id, lib.Name)
			}
		}
	})
}

func (s *Server) requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	user := currentUser(r)
	if user == nil || !user.IsAdmin {
		writeError(w, http.StatusForbidden, "需要管理员权限")
		return false
	}
	return true
}

// lookupLibrary 支持按 name 或 id 定位媒体库。
func (s *Server) lookupLibrary(w http.ResponseWriter, r *http.Request) *store.Library {
	params := r.URL.Query()

	var (
		lib *store.Library
		err error
	)
	switch {
	case strings.TrimSpace(params.Get("id")) != "":
		lib, err = s.store.LibraryByID(r.Context(), strings.TrimSpace(params.Get("id")))
	case strings.TrimSpace(params.Get("name")) != "":
		lib, err = s.store.LibraryByName(r.Context(), strings.TrimSpace(params.Get("name")))
	default:
		writeError(w, http.StatusBadRequest, "缺少 name 或 id 参数")
		return nil
	}

	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "媒体库不存在")
		return nil
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "查询媒体库失败")
		return nil
	}
	return lib
}

// parsePaths 读取 paths 参数：支持重复出现多次，也支持用 ; 分隔。
func parsePaths(params url.Values) []string {
	values, ok := params["paths"]
	if !ok {
		return nil
	}

	expanded := make([]string, 0, len(values))
	for _, value := range values {
		expanded = append(expanded, strings.Split(value, ";")...)
	}
	return normalizePathList(expanded)
}

func normalizePathList(values []string) []string {
	paths := make([]string, 0, len(values))
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		paths = append(paths, value)
	}
	return paths
}
