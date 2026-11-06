package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"embyx/internal/dto"
)

// TestParseItemQuery 校验列表参数到查询结构的映射：客户端参数名、布尔开关、
// 排序默认值这些细节最容易改出回归，因此按表格逐项比对。
func TestParseItemQuery(t *testing.T) {
	// 排序缺省：客户端不传 SortBy / SortOrder 时必须回落到 SortName + Ascending。
	request := httptest.NewRequest(http.MethodGet, "/emby/Users/u1/Items", nil)
	request.SetPathValue("userId", "u1")
	query := parseItemQuery(request)
	if query.UserID != "u1" {
		t.Errorf("UserID = %q，期望 u1", query.UserID)
	}
	if len(query.SortBy) != 1 || query.SortBy[0] != "SortName" || query.SortOrder != "Ascending" {
		t.Errorf("排序缺省值 = %v %q", query.SortBy, query.SortOrder)
	}

	// 全量参数：逐项对照客户端实际使用的写法（大小写混排的 CSV）。
	request = httptest.NewRequest(http.MethodGet, "/emby/Users/u2/Items?"+
		"ParentId=lib1&IncludeItemTypes=Movie,Video&SearchTerm=beta&Years=2020,2021"+
		"&PersonIds=p1&GenreIds=%E5%89%A7%E6%83%85&TagIds=4K&StudioIds=s1"+
		"&Filters=IsFavorite,IsPlayed&MinCommunityRating=7.5&SortBy=DateCreated&SortOrder=Descending"+
		"&StartIndex=20&Limit=50", nil)
	request.SetPathValue("userId", "u2")
	query = parseItemQuery(request)

	if query.ParentID != "lib1" || len(query.IncludeTypes) != 2 || query.SearchTerm != "beta" {
		t.Errorf("基础条件不符: %+v", query)
	}
	if len(query.Years) != 2 || query.Years[0] != 2020 || query.Years[1] != 2021 {
		t.Errorf("Years = %v", query.Years)
	}
	if len(query.PersonIDs) != 1 || len(query.GenreIDs) != 1 || len(query.TagIDs) != 1 || len(query.StudioIDs) != 1 {
		t.Errorf("筛选列表不符: %+v", query)
	}
	if !query.FavoriteOnly || !query.IsPlayed || query.IsUnplayed || query.IsResumable {
		t.Errorf("Filters 解析不符: %+v", query)
	}
	if query.MinCommunityRating == nil || *query.MinCommunityRating != 7.5 {
		t.Errorf("MinCommunityRating = %v", query.MinCommunityRating)
	}
	if query.StartIndex != 20 || query.Limit != 50 {
		t.Errorf("分页参数 = %d/%d", query.StartIndex, query.Limit)
	}
	if len(query.SortBy) != 1 || query.SortBy[0] != "DateCreated" || query.SortOrder != "Descending" {
		t.Errorf("排序参数 = %v %q", query.SortBy, query.SortOrder)
	}

	// 非法数字不能把请求打挂：缺省成 0，交给存储层钳制。
	if query := parseItemQuery(httptest.NewRequest(
		http.MethodGet, "/emby/Users/u1/Items?StartIndex=abc&MinCommunityRating=x", nil)); query.StartIndex != 0 || query.MinCommunityRating != nil {
		t.Errorf("非法数值应回落默认值: %+v", query)
	}
}

// TestFieldsNeedDetail 列表默认瘦身，只有显式要详情字段时才输出完整形态。
func TestFieldsNeedDetail(t *testing.T) {
	cases := []struct {
		name   string
		fields string
		want   bool
	}{
		{"空参数", "", false},
		{"卡片字段", "ProductionYear,PremiereDate,CommunityRating,RunTimeTicks", false},
		{"要媒体源", "Overview,MediaSources", true},
		{"要演员", "people", true},
		{"要章节", "Chapters", true},
	}
	for _, tc := range cases {
		if got := fieldsNeedDetail(tc.fields); got != tc.want {
			t.Errorf("%s: fieldsNeedDetail(%q) = %v，期望 %v", tc.name, tc.fields, got, tc.want)
		}
	}
}

// TestBifIntervalParam 播放侧的抽帧间隔默认 10 秒，显式传参时按参数走。
func TestBifIntervalParam(t *testing.T) {
	cases := []struct {
		name   string
		target string
		want   uint32
	}{
		{"缺省", "/emby/Videos/i1/index.bif", 10000},
		{"显式间隔", "/emby/Videos/i1/index.bif?IntervalMs=5000", 5000},
		{"小写参数名", "/emby/Videos/i1/index.bif?intervalMs=2000", 2000},
		{"非法值回落", "/emby/Videos/i1/index.bif?IntervalMs=-1", 10000},
	}
	for _, tc := range cases {
		request := httptest.NewRequest(http.MethodGet, tc.target, nil)
		if got := bifIntervalParam(request); got != tc.want {
			t.Errorf("%s: bifIntervalParam = %d，期望 %d", tc.name, got, tc.want)
		}
	}
}

// TestListOmitsDetailFields 列表接口不应再带 People / MediaSources，
// 详情接口仍要完整返回：客户端靠它渲染演员表与版本选择器。
func TestListOmitsDetailFields(t *testing.T) {
	env := newTestEnv(t)
	seedItems(t, env.store)

	listPath := "/emby/Users/" + env.userID + "/Items?Limit=10"
	recorder := doRequest(env.server, http.MethodGet, listPath, env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("列表状态码 = %d", recorder.Code)
	}
	var page dto.QueryResult
	decodeBody(t, recorder, &page)
	if len(page.Items) == 0 {
		t.Fatal("列表为空，无法验证字段瘦身")
	}
	for _, item := range page.Items {
		if len(item.People) != 0 {
			t.Errorf("列表条目 %s 不应包含 People", item.ID)
		}
		if len(item.MediaSources) != 0 {
			t.Errorf("列表条目 %s 不应包含 MediaSources", item.ID)
		}
	}

	// 详情接口保持完整。
	recorder = doRequest(env.server, http.MethodGet, "/emby/Users/"+env.userID+"/Items/i1", env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("详情状态码 = %d", recorder.Code)
	}
	var detail dto.BaseItemDto
	decodeBody(t, recorder, &detail)
	if len(detail.People) == 0 {
		t.Error("详情条目应包含 People")
	}
	// 显式要 People 的列表请求同样走完整形态。
	recorder = doRequest(env.server, http.MethodGet, listPath+"&Fields=People", env.token, "")
	decodeBody(t, recorder, &page)
	if len(page.Items) == 0 || len(page.Items[0].People) == 0 {
		t.Error("Fields=People 时应返回演员列表")
	}
}

// TestUpdatePersonMetadataRoute 演员编辑复用 POST /emby/Items/{personId}：
// 新字段要能在人物详情读到，改名也要立刻反映到关联影片的演员表。
func TestUpdatePersonMetadataRoute(t *testing.T) {
	env := newTestEnv(t)
	seedItems(t, env.store)

	body := `{"Name":"张三丰","Overview":"演员介绍","BirthDate":"1985-06-01",` +
		`"PremiereDate":"2005-01-01","Gender":"Female","CupSize":"D","ProviderIds":{"Tmdb":"123"}}`
	if recorder := doRequest(env.server, http.MethodPost, "/emby/Items/p1", env.token, body); recorder.Code != http.StatusNoContent {
		t.Fatalf("保存演员信息状态码 = %d: %s", recorder.Code, recorder.Body.String())
	}

	recorder := doRequest(env.server, http.MethodGet, "/emby/Users/"+env.userID+"/Items/p1", env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("人物详情状态码 = %d", recorder.Code)
	}
	var person dto.BaseItemDto
	decodeBody(t, recorder, &person)
	if person.Name != "张三丰" || person.Overview != "演员介绍" || person.Gender != "Female" {
		t.Fatalf("演员详情未更新: %+v", person)
	}
	if person.BirthDate != "1985-06-01" || person.PremiereDate != "2005-01-01" || person.CupSize != "D" {
		t.Fatalf("演员日期/罩杯字段不符: %+v", person)
	}
	if person.ProviderIDs["Tmdb"] != "123" {
		t.Fatalf("演员外部编号不符: %v", person.ProviderIDs)
	}

	// 条目详情里的演员表取自主表，改名后应立刻生效。
	recorder = doRequest(env.server, http.MethodGet, "/emby/Users/"+env.userID+"/Items/i1", env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("条目详情状态码 = %d", recorder.Code)
	}
	var item dto.BaseItemDto
	decodeBody(t, recorder, &item)
	if len(item.People) == 0 || item.People[0].Name != "张三丰" {
		t.Fatalf("关联影片的演员表未跟随更新: %+v", item.People)
	}
}

// TestLogoutInvalidatesToken 登出后令牌立即失效。
func TestLogoutInvalidatesToken(t *testing.T) {
	env := newTestEnv(t)
	listPath := "/emby/Users/" + env.userID + "/Items"

	if recorder := doRequest(env.server, http.MethodPost, "/emby/Sessions/Logout", env.token, ""); recorder.Code != http.StatusNoContent {
		t.Fatalf("登出状态码 = %d", recorder.Code)
	}
	recorder := doRequest(env.server, http.MethodGet, listPath, env.token, "")
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("登出后仍可访问，得到 %d", recorder.Code)
	}
	if body := strings.TrimSpace(recorder.Body.String()); body == "" {
		t.Error("401 响应应带错误体")
	}
}
