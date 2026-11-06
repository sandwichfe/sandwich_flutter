package httpapi

import (
	"net/http"
	"testing"
)

// TestPersonScrapeRoutesWhenNotConfigured 验证没配 TMDB Key 时接口给出明确提示，
// 而不是静默返回空任务列表。
func TestPersonScrapeRoutesWhenNotConfigured(t *testing.T) {
	env := newTestEnv(t)
	seedItems(t, env.store)

	recorder := doRequest(env.server, http.MethodPost, "/emby/PersonScrapeJobs", env.token, `{"Mode":"all"}`)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("创建任务状态码 = %d, 期望 400: %s", recorder.Code, recorder.Body.String())
	}

	recorder = doRequest(env.server, http.MethodGet, "/emby/PersonScrapeJobs", env.token, "")
	if recorder.Code != http.StatusOK {
		t.Fatalf("任务列表状态码 = %d", recorder.Code)
	}
	var response personScrapeJobsDto
	decodeBody(t, recorder, &response)
	if response.Configured {
		t.Fatal("未配置 Key 时 Configured 应为 false")
	}
	if len(response.Jobs) != 0 {
		t.Fatalf("未配置时不应有任务: %+v", response.Jobs)
	}

	recorder = doRequest(env.server, http.MethodPost, "/emby/Persons/p1/Scrape", env.token, "")
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("单人刮削状态码 = %d, 期望 400", recorder.Code)
	}
}
