package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// doAuthedRequest 用自定义鉴权方式发请求，覆盖 api_key / 各种头部的写法。
func doAuthedRequest(server *Server, method, target string, headers map[string]string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, target, nil)
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	recorder := httptest.NewRecorder()
	server.Handler().ServeHTTP(recorder, request)
	return recorder
}

func TestAuthPublicPathsNeedNoToken(t *testing.T) {
	env := newTestEnv(t)

	if recorder := doRequest(env.server, http.MethodGet, "/emby/System/Info/Public", "", ""); recorder.Code != http.StatusOK {
		t.Fatalf("公开信息接口应免鉴权，得到 %d", recorder.Code)
	}
	// 登录接口免鉴权，但密码错误仍要 401。
	recorder := doRequest(env.server, http.MethodPost, "/emby/Users/AuthenticateByName", "",
		`{"Username":"admin","Pw":"wrong"}`)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("错误密码应返回 401，得到 %d", recorder.Code)
	}
	if _, exists := decodeErrorBody(t, recorder)["message"]; !exists {
		t.Error("错误响应应包含 message 字段")
	}
}

func TestAuthAnonymousRejectedEverywhere(t *testing.T) {
	env := newTestEnv(t)

	requests := []struct {
		method string
		target string
	}{
		{http.MethodGet, "/emby/Users/" + env.userID + "/Items"},
		{http.MethodGet, "/emby/Users/" + env.userID + "/Items/Resume"},
		{http.MethodGet, "/emby/Library/ScanStatus"},
		{http.MethodPost, "/emby/Library/Refresh"},
		{http.MethodGet, "/emby/Videos/item1/stream"},
		{http.MethodGet, "/emby/Items/item1/Images/Primary"},
		{http.MethodDelete, "/emby/Items/item1/Images/Primary/0"},
		{http.MethodGet, "/emby/Genres"},
	}
	for _, request := range requests {
		recorder := doRequest(env.server, request.method, request.target, "", "")
		if recorder.Code != http.StatusUnauthorized {
			t.Errorf("%s %s 未登录返回 %d，期望 401", request.method, request.target, recorder.Code)
			continue
		}
		body := decodeErrorBody(t, recorder)
		if body["status"] != float64(http.StatusUnauthorized) {
			t.Errorf("%s 错误体 status 字段 = %v", request.target, body["status"])
		}
	}

	// 伪造令牌与伪造 api_key 同样按未登录处理。
	if recorder := doRequest(env.server, http.MethodGet, "/emby/Users/"+env.userID+"/Items", "fake-token", ""); recorder.Code != http.StatusUnauthorized {
		t.Errorf("伪造令牌返回 %d，期望 401", recorder.Code)
	}
	if recorder := doAuthedRequest(env.server, http.MethodGet,
		"/emby/Users/"+env.userID+"/Items?api_key=fake-token", nil); recorder.Code != http.StatusUnauthorized {
		t.Errorf("伪造 api_key 返回 %d，期望 401", recorder.Code)
	}
}

func TestAuthTokenSources(t *testing.T) {
	env := newTestEnv(t)
	listPath := "/emby/Users/" + env.userID + "/Items"

	cases := []struct {
		name    string
		target  string
		headers map[string]string
	}{
		// 图片与视频地址只能拼 query，所以 api_key 必须和头部等效。
		{"api_key 查询参数", listPath + "?api_key=" + env.token, nil},
		{"ApiKey 大小写变体", listPath + "?ApiKey=" + env.token, nil},
		{"X-MediaBrowser-Token 头", listPath, map[string]string{"X-MediaBrowser-Token": env.token}},
		{"Authorization 头", listPath, map[string]string{
			"Authorization": `MediaBrowser Client="test", Token="` + env.token + `"`,
		}},
	}
	for _, tc := range cases {
		recorder := doAuthedRequest(env.server, http.MethodGet, tc.target, tc.headers)
		if recorder.Code != http.StatusOK {
			t.Errorf("%s 返回 %d，期望 200（body=%s）", tc.name, recorder.Code, recorder.Body.String())
		}
	}
}

func TestAuthRoleMatrix(t *testing.T) {
	env := newTestEnv(t)

	bob, err := env.store.CreateUser("bob", "pw", false)
	if err != nil {
		t.Fatalf("创建普通用户失败: %v", err)
	}
	bobToken, err := env.store.CreateToken(bob.ID)
	if err != nil {
		t.Fatalf("签发普通用户令牌失败: %v", err)
	}
	listPath := "/emby/Users/" + bob.ID + "/Items"

	// 普通用户：媒体浏览类接口可用，管理接口一律 403（而不是 401）。
	if recorder := doRequest(env.server, http.MethodGet, listPath, bobToken, ""); recorder.Code != http.StatusOK {
		t.Errorf("普通用户浏览列表返回 %d，期望 200", recorder.Code)
	}
	if recorder := doRequest(env.server, http.MethodGet, "/emby/Genres", bobToken, ""); recorder.Code != http.StatusOK {
		t.Errorf("普通用户浏览分类返回 %d，期望 200", recorder.Code)
	}
	// 媒体库列表只读，普通用户也要能拿到（侧栏渲染）。
	if recorder := doRequest(env.server, http.MethodGet, "/emby/Library/VirtualFolders", bobToken, ""); recorder.Code != http.StatusOK {
		t.Errorf("普通用户读取媒体库列表返回 %d，期望 200", recorder.Code)
	}

	adminOnly := []struct {
		method string
		target string
	}{
		{http.MethodGet, "/emby/Library/ScanStatus"},
		{http.MethodPost, "/emby/Library/Refresh"},
		{http.MethodPost, "/emby/Items/item1"},
		{http.MethodPost, "/emby/Items/item1/Refresh"},
		{http.MethodPost, "/emby/ThumbnailJobs"},
		{http.MethodPost, "/emby/ArtworkJobs"},
		{http.MethodDelete, "/emby/Items/item1/Images/Primary/0"},
	}
	for _, request := range adminOnly {
		recorder := doRequest(env.server, request.method, request.target, bobToken, "")
		if recorder.Code != http.StatusForbidden {
			t.Errorf("普通用户 %s %s 返回 %d，期望 403", request.method, request.target, recorder.Code)
		}
	}

	// 头像上传按「本人或管理员」判定：改别人的 403，改自己的只是请求体不合法 400。
	if recorder := doRequest(env.server, http.MethodPost,
		"/emby/Users/"+env.userID+"/Images/Primary", bobToken, ""); recorder.Code != http.StatusForbidden {
		t.Errorf("普通用户修改他人头像返回 %d，期望 403", recorder.Code)
	}
	if recorder := doRequest(env.server, http.MethodPost,
		"/emby/Users/"+bob.ID+"/Images/Primary", bobToken, ""); recorder.Code != http.StatusBadRequest {
		t.Errorf("普通用户上传自己头像返回 %d，期望 400（越过权限检查后才发现内容为空）", recorder.Code)
	}

	// 管理员走同一批接口应通过权限检查。
	if recorder := doRequest(env.server, http.MethodGet, "/emby/Library/ScanStatus", env.token, ""); recorder.Code != http.StatusOK {
		t.Errorf("管理员读取扫描进度返回 %d，期望 200", recorder.Code)
	}
	if recorder := doRequest(env.server, http.MethodGet, "/emby/Library/VirtualFolders", env.token, ""); recorder.Code != http.StatusOK {
		t.Errorf("管理员读取媒体库列表返回 %d，期望 200", recorder.Code)
	}
}

func TestAuthRevokedTokenRejected(t *testing.T) {
	env := newTestEnv(t)
	listPath := "/emby/Users/" + env.userID + "/Items"

	if recorder := doRequest(env.server, http.MethodGet, listPath, env.token, ""); recorder.Code != http.StatusOK {
		t.Fatalf("有效令牌应返回 200，得到 %d", recorder.Code)
	}
	// 退出登录后令牌立即失效：tokens 表没有过期时间，删除是唯一的失效方式。
	if err := env.store.DeleteToken(env.token); err != nil {
		t.Fatalf("删除令牌失败: %v", err)
	}
	if recorder := doRequest(env.server, http.MethodGet, listPath, env.token, ""); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("已注销令牌应返回 401，得到 %d", recorder.Code)
	}
}

// decodeErrorBody 解析 JSON 错误体，S0 之后错误响应统一是 {"message","status"}。
func decodeErrorBody(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("错误响应不是 JSON: %v（body=%s）", err, recorder.Body.String())
	}
	return body
}
