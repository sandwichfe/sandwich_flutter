package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"embyx/internal/config"
	"embyx/internal/dto"
	"embyx/internal/media"
	"embyx/internal/store"
)

type testEnv struct {
	server *Server
	store  *store.Store
	userID string
	token  string
}

// newTestEnv 起一个不监听端口的服务实例，媒体相关组件只做构造不做 IO，
// 因此不需要真实的 ffmpeg 就能验证路由与 JSON 形态。
func newTestEnv(t *testing.T) *testEnv {
	t.Helper()

	cfg := config.Default()
	cfg.DataDir = t.TempDir()

	st, err := store.Open(filepath.Join(cfg.DataDir, "embyx.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.EnsureAdmin(cfg.AdminUser, cfg.AdminPassword); err != nil {
		t.Fatalf("初始化管理员失败: %v", err)
	}

	images := media.NewImageStore(filepath.Join(cfg.DataDir, "images"))
	bif := media.NewBifCache(filepath.Join(cfg.DataDir, "cache", "bif"), cfg.FFmpegPath)
	prober := media.NewProber(cfg.FFprobePath)
	scanner := media.NewScanner(st, prober, images, bif)
	server := New(cfg, st, images, bif, scanner, media.NewThumbnailJobManager(bif), prober, nil)

	recorder := doRequest(server, http.MethodPost, "/emby/Users/AuthenticateByName", "",
		`{"Username":"admin","Pw":"admin"}`)
	if recorder.Code != http.StatusOK {
		t.Fatalf("登录失败: %d %s", recorder.Code, recorder.Body.String())
	}
	var auth dto.AuthenticationResult
	decodeBody(t, recorder, &auth)
	if auth.AccessToken == "" || auth.User == nil {
		t.Fatalf("登录响应缺少令牌或用户: %+v", auth)
	}

	return &testEnv{server: server, store: st, userID: auth.User.ID, token: auth.AccessToken}
}

func doRequest(server *Server, method, target, token, body string) *httptest.ResponseRecorder {
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request := httptest.NewRequest(method, target, reader)
	if token != "" {
		request.Header.Set("X-Emby-Token", token)
	}
	recorder := httptest.NewRecorder()
	server.Handler().ServeHTTP(recorder, request)
	return recorder
}

func decodeBody(t *testing.T, recorder *httptest.ResponseRecorder, target any) {
	t.Helper()
	if err := json.Unmarshal(recorder.Body.Bytes(), target); err != nil {
		t.Fatalf("解析响应失败: %v（body=%s）", err, recorder.Body.String())
	}
}

func seedItems(t *testing.T, st *store.Store) {
	t.Helper()
	items := []*store.Item{
		{
			ID: "i1", LibraryID: "lib1", ParentID: "lib1", Type: "Movie",
			Name: "Alpha", SortName: "Alpha", DateCreated: "2024-01-01T00:00:00Z",
			Genres: []string{"剧情"}, Tags: []string{"4K"},
			Studios: []dto.NameIDPair{{ID: "studio1", Name: "A24"}},
			People:  []dto.PersonDto{{ID: "p1", Name: "张三", Type: "Actor", Role: "主演"}},
		},
		{
			ID: "i2", LibraryID: "lib1", ParentID: "lib1", Type: "Movie",
			Name: "Beta", SortName: "Beta", DateCreated: "2025-01-01T00:00:00Z",
			Genres: []string{"剧情", "科幻"}, Tags: []string{"蓝光"},
			Studios: []dto.NameIDPair{{ID: "studio1", Name: "A24"}},
			People:  []dto.PersonDto{{ID: "p1", Name: "张三", Type: "Actor", Role: "主演"}},
		},
	}
	for _, item := range items {
		if err := st.UpsertItem(context.Background(), item); err != nil {
			t.Fatalf("写入条目失败: %v", err)
		}
	}
}

func TestFacetAndFilterRoutes(t *testing.T) {
	env := newTestEnv(t)
	seedItems(t, env.store)
	userItems := "/emby/Users/" + env.userID + "/Items"

	recorder := doRequest(env.server, http.MethodGet, "/emby/Genres", env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("Genres 状态码 = %d", recorder.Code)
	}
	var genres dto.QueryResult
	decodeBody(t, recorder, &genres)
	if len(genres.Items) != 2 {
		t.Fatalf("流派数 = %d，期望 2", len(genres.Items))
	}
	for _, item := range genres.Items {
		if item.ID != item.Name || item.Type != "Genre" {
			t.Errorf("流派标识不符合约定: %+v", item)
		}
		if item.ChildCount == nil {
			t.Errorf("流派缺少 ChildCount: %+v", item)
		}
	}

	recorder = doRequest(env.server, http.MethodGet, "/emby/Studios", env.token, "")
	var studios dto.QueryResult
	decodeBody(t, recorder, &studios)
	if len(studios.Items) != 1 || studios.Items[0].ID != "studio1" {
		t.Fatalf("工作室结果不符合预期: %+v", studios.Items)
	}

	recorder = doRequest(env.server, http.MethodGet, "/emby/Tags", env.token, "")
	var tags dto.QueryResult
	decodeBody(t, recorder, &tags)
	if len(tags.Items) != 2 {
		t.Fatalf("标签数 = %d，期望 2", len(tags.Items))
	}

	// 分类浏览返回的 Id 原样回传即可筛选。
	recorder = doRequest(env.server, http.MethodGet,
		userItems+"?GenreIds=%E5%89%A7%E6%83%85", env.token, "")
	var byGenre dto.QueryResult
	decodeBody(t, recorder, &byGenre)
	if byGenre.TotalRecordCount != 2 {
		t.Fatalf("按流派筛选 total=%d，期望 2", byGenre.TotalRecordCount)
	}

	recorder = doRequest(env.server, http.MethodGet,
		userItems+"?StudioIds=studio1&Filters=IsUnplayed", env.token, "")
	var byStudio dto.QueryResult
	decodeBody(t, recorder, &byStudio)
	if byStudio.TotalRecordCount != 2 {
		t.Fatalf("按工作室 + 未观看筛选 total=%d，期望 2", byStudio.TotalRecordCount)
	}
}

func TestLatestItemsRoute(t *testing.T) {
	env := newTestEnv(t)
	seedItems(t, env.store)

	recorder := doRequest(env.server, http.MethodGet,
		"/emby/Users/"+env.userID+"/Items/Latest?Limit=1", env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("Latest 状态码 = %d", recorder.Code)
	}
	var items []dto.BaseItemDto
	decodeBody(t, recorder, &items)
	if len(items) != 1 || items[0].Name != "Beta" {
		t.Fatalf("Latest 返回不符合预期: %+v", items)
	}

	// Limit 缺省时用 20，必须返回数组而不是 QueryResult。
	recorder = doRequest(env.server, http.MethodGet, "/emby/Users/"+env.userID+"/Items/Latest", env.token, "")
	if body := strings.TrimSpace(recorder.Body.String()); !strings.HasPrefix(body, "[") {
		t.Fatalf("Latest 应返回数组，得到: %s", body)
	}
}

func TestScanStatusRoute(t *testing.T) {
	env := newTestEnv(t)

	recorder := doRequest(env.server, http.MethodGet, "/emby/Library/ScanStatus", env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("ScanStatus 状态码 = %d", recorder.Code)
	}
	var status scanStatusDto
	decodeBody(t, recorder, &status)
	if status.Running || status.StartedAt != "" {
		t.Fatalf("未扫描时状态不符合预期: %+v", status)
	}
	// failures 必须是 []，不能是 null。
	if !strings.Contains(recorder.Body.String(), `"failures":[]`) {
		t.Fatalf("failures 应为空数组: %s", recorder.Body.String())
	}

	// 非管理员或未登录都拿不到扫描状态。
	if recorder := doRequest(env.server, http.MethodGet, "/emby/Library/ScanStatus", "", ""); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("匿名请求状态码 = %d，期望 401", recorder.Code)
	}
}
