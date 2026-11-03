package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"

	"embyx/internal/dto"
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
}

func libraryToDto(lib store.Library) dto.BaseItemDto {
	locations := lib.Paths
	if locations == nil {
		locations = []string{}
	}
	return dto.BaseItemDto{
		ID:             lib.ID,
		Name:           lib.Name,
		Type:           "CollectionFolder",
		CollectionType: lib.CollectionType,
		IsFolder:       true,
		Locations:      locations,
		ImageTags:      map[string]string{},
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
		items = append(items, libraryToDto(lib))
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

	result := make([]virtualFolderDto, 0, len(libraries))
	for _, lib := range libraries {
		count, countErr := s.store.CountLibraryItems(r.Context(), lib.ID)
		if countErr != nil {
			count = 0
		}
		result = append(result, virtualFolderDto{
			Name:           lib.Name,
			Locations:      lib.Paths,
			CollectionType: lib.CollectionType,
			ItemId:         lib.ID,
			ItemCount:      count,
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
		lib = &store.Library{Name: name, CollectionType: "movies"}
	}

	if collectionType := strings.TrimSpace(params.Get("collectionType")); collectionType != "" {
		lib.CollectionType = collectionType
	}
	if paths != nil {
		lib.Paths = paths
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
	}
	log.Printf("已删除媒体库 %s，同时清理 %d 个条目", lib.Name, len(itemIDs))
	writeNoContent(w)
}

// handleLibraryRefresh POST /Library/Refresh 扫描全部媒体库。
func (s *Server) handleLibraryRefresh(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	go func() {
		if _, err := s.scanner.ScanAll(context.Background(), log.Printf); err != nil {
			log.Printf("媒体库扫描失败: %v", err)
		}
	}()
	writeNoContent(w)
}

func (s *Server) scanLibraryAsync(lib *store.Library) {
	target := *lib
	go func() {
		if _, err := s.scanner.ScanLibrary(context.Background(), target, log.Printf); err != nil {
			log.Printf("媒体库 %s 扫描失败: %v", target.Name, err)
		}
	}()
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
