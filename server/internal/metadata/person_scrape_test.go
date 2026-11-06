package metadata

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"embyx/internal/dto"
	"embyx/internal/media"
	"embyx/internal/store"
)

// fakeTMDB 模拟 TMDB 的四个接口与自己 CDN，测试里不产生任何真实网络请求。
type fakeTMDB struct {
	server *httptest.Server
	// searchResults 由具体用例替换，用于覆盖重名场景。
	searchResults []SearchResult
	imageBytes    []byte
}

func newFakeTMDB(t *testing.T) *fakeTMDB {
	t.Helper()

	buffer := &bytes.Buffer{}
	if err := png.Encode(buffer, image.NewRGBA(image.Rect(0, 0, 4, 4))); err != nil {
		t.Fatalf("生成测试图片失败: %v", err)
	}
	fake := &fakeTMDB{imageBytes: buffer.Bytes()}

	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/person/42":
			writeJSON(t, w, Person{
				ID:          42,
				Name:        "张三",
				Biography:   "演员简介",
				Birthday:    "1985-06-01",
				Gender:      1,
				ProfilePath: "/profile.jpg",
			})
		case "/person/42/external_ids":
			writeJSON(t, w, ExternalIDs{IMDBID: "nm42"})
		case "/person/42/images":
			writeJSON(t, w, PersonImages{Profiles: []Image{
				{FilePath: "/profile.jpg", VoteAverage: 9},
				{FilePath: "/backdrop1.jpg", VoteAverage: 5},
				{FilePath: "/backdrop2.jpg", VoteAverage: 3},
			}})
		case "/movie/550/credits":
			writeJSON(t, w, MovieCredits{
				Cast: []Credit{{ID: 42, Name: "张三", Character: "主角"}},
				Crew: []Credit{{ID: 77, Name: "张三", Job: "Director"}},
			})
		case "/search/person":
			writeJSON(t, w, searchResponse{Results: fake.searchResults})
		default:
			// 图片下载（/w780/xxx.jpg）。
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(fake.imageBytes)
		}
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func writeJSON(t *testing.T, w http.ResponseWriter, value any) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(value); err != nil {
		t.Fatalf("写测试响应失败: %v", err)
	}
}

func newTestScraper(t *testing.T, fake *fakeTMDB, maxBackdrops int) (*PersonScraper, *store.Store, *media.ImageStore) {
	t.Helper()

	st, err := store.Open(filepath.Join(t.TempDir(), "embyx.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	images := media.NewImageStore(filepath.Join(t.TempDir(), "images"))
	client, err := NewClient("test-key", "zh-CN", "")
	if err != nil {
		t.Fatalf("创建客户端失败: %v", err)
	}
	// 指向假服务，避免测试联网。
	client.SetEndpoints(fake.server.URL, fake.server.URL)
	return NewPersonScraper(st, images, client, maxBackdrops), st, images
}

func seedPerson(t *testing.T, st *store.Store, tmdbID string) store.PersonScrapeTarget {
	t.Helper()

	item := &store.Item{
		ID:          "i1",
		LibraryID:   "lib1",
		ParentID:    "lib1",
		Type:        "Movie",
		Name:        "Alpha",
		SortName:    "Alpha",
		DateCreated: store.NowISO(),
		People:      []dto.PersonDto{{ID: "p1", Name: "张三", Type: "Actor", Role: "主演"}},
		ProviderIDs: map[string]string{"Tmdb": "550"},
	}
	if err := st.UpsertItem(context.Background(), item); err != nil {
		t.Fatalf("写入条目失败: %v", err)
	}
	target, err := st.PersonScrapeTargetByID(context.Background(), "p1")
	if err != nil {
		t.Fatalf("读取演员失败: %v", err)
	}
	if tmdbID != "" {
		if _, err := st.ApplyScrapedPerson(context.Background(), "p1", store.ScrapedPersonData{
			ProviderIDs: map[string]string{"Tmdb": tmdbID},
		}, false); err != nil {
			t.Fatalf("预置 Tmdb 编号失败: %v", err)
		}
		target.ProviderIDs = map[string]string{"Tmdb": tmdbID}
	}
	return *target
}

// TestScrapePersonWritesProfileAndImages 覆盖完整链路：资料写库 + 头像/写真落盘。
func TestScrapePersonWritesProfileAndImages(t *testing.T) {
	fake := newFakeTMDB(t)
	scraper, st, images := newTestScraper(t, fake, 2)
	ctx := context.Background()

	target := seedPerson(t, st, "42")
	outcome, err := scraper.Scrape(ctx, target, false)
	if err != nil {
		t.Fatalf("刮削失败: %v", err)
	}
	if outcome.State != store.PersonMatchMatched || !outcome.Updated {
		t.Fatalf("刮削结果不符: %+v", outcome)
	}
	// 头像 1 张 + 写真上限 2 张。
	if outcome.Images != 3 {
		t.Fatalf("图片数量 = %d, 期望 3", outcome.Images)
	}

	person, err := st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if person.Overview != "演员简介" || person.BirthDate != "1985-06-01" || person.Gender != "Female" {
		t.Fatalf("资料未写入: %+v", person)
	}
	if person.ProviderIDs["Tmdb"] != "42" || person.ProviderIDs["Imdb"] != "nm42" {
		t.Fatalf("外部编号未写入: %v", person.ProviderIDs)
	}
	if person.PrimaryImageTag == "" || len(person.BackdropImageTags) != 2 {
		t.Fatalf("图片标记未回写: 头像=%q 写真=%v", person.PrimaryImageTag, person.BackdropImageTags)
	}

	// 图片真的落到了盘上。
	if !images.HasItemImage("p1", "Primary", 0) {
		t.Error("头像文件缺失")
	}
	for index := 0; index < 2; index++ {
		if !images.HasItemImage("p1", "Backdrop", index) {
			t.Errorf("写真 %d 缺失", index)
		}
	}
	if origin := images.ReadOrigin("p1", "Backdrop", 0); origin != media.OriginAuto {
		t.Errorf("写真来源标记 = %q, 期望 %q", origin, media.OriginAuto)
	}
}

// TestClientRateLimitSpacing 验证请求之间真的按配置的速率排队，
// 这是「不要被官方接口拉黑」的核心保障。
func TestClientRateLimitSpacing(t *testing.T) {
	var requests int
	// 简介不为空，避免触发 en-US 回退请求干扰计数。
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		writeJSON(t, w, Person{ID: 42, Name: "张三", Biography: "简介"})
	}))
	defer server.Close()

	client, err := NewClient("test-key", "zh-CN", "")
	if err != nil {
		t.Fatalf("创建客户端失败: %v", err)
	}
	client.SetEndpoints(server.URL, server.URL)
	client.SetRateLimit(10) // 100ms 一次
	if client.RateLimit() != 10 {
		t.Fatalf("速率设置未生效: %d", client.RateLimit())
	}

	started := time.Now()
	for index := 0; index < 3; index++ {
		if _, err := client.Person(context.Background(), "42"); err != nil {
			t.Fatalf("请求失败: %v", err)
		}
	}
	elapsed := time.Since(started)
	if requests != 3 {
		t.Fatalf("请求次数 = %d", requests)
	}
	// 3 次请求至少要有 2 个间隔。
	if minimum := 200 * time.Millisecond; elapsed < minimum {
		t.Fatalf("3 次请求仅用 %s，限速未生效（至少 %s）", elapsed, minimum)
	}

	// 越界的速率会被夹到 1~10。
	client.SetRateLimit(999)
	if client.RateLimit() != 10 {
		t.Fatalf("速率上限未夹紧: %d", client.RateLimit())
	}
	client.SetRateLimit(0)
	if client.RateLimit() != 4 {
		t.Fatalf("非法速率应回落默认值: %d", client.RateLimit())
	}
}

// TestClientRetryAfterCooldown 验证 429 时遵守 Retry-After，并让整个客户端一起冷却。
func TestClientRetryAfterCooldown(t *testing.T) {
	var attempts int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		writeJSON(t, w, Person{ID: 42, Name: "张三", Biography: "简介"})
	}))
	defer server.Close()

	client, err := NewClient("test-key", "zh-CN", "")
	if err != nil {
		t.Fatalf("创建客户端失败: %v", err)
	}
	client.SetEndpoints(server.URL, server.URL)
	client.SetRateLimit(10)

	started := time.Now()
	person, err := client.Person(context.Background(), "42")
	if err != nil {
		t.Fatalf("重试后应成功: %v", err)
	}
	if person.ID != 42 || attempts != 2 {
		t.Fatalf("重试结果不符: id=%d attempts=%d", person.ID, attempts)
	}
	if elapsed := time.Since(started); elapsed < time.Second {
		t.Fatalf("未遵守 Retry-After，仅等待 %s", elapsed)
	}
}

// TestScrapePersonResolvesByMovieCredits 验证没有 Tmdb 编号时用影片演职员表反查。
func TestScrapePersonResolvesByMovieCredits(t *testing.T) {
	fake := newFakeTMDB(t)
	scraper, st, _ := newTestScraper(t, fake, 0)
	ctx := context.Background()

	target := seedPerson(t, st, "")
	// 搜索结果故意给错，确保走的是 credits 而不是搜索。
	fake.searchResults = []SearchResult{{ID: 999, Name: "张三"}}

	outcome, err := scraper.Scrape(ctx, target, false)
	if err != nil {
		t.Fatalf("刮削失败: %v", err)
	}
	if outcome.State != store.PersonMatchMatched {
		t.Fatalf("应通过演职员表匹配成功: %+v", outcome)
	}
	person, _ := st.PersonByID(ctx, "p1")
	if person.ProviderIDs["Tmdb"] != "42" {
		t.Fatalf("匹配到的编号不符: %v", person.ProviderIDs)
	}
}

// TestScrapePersonAmbiguousMatchSkipped 验证重名且无法交叉验证时不写任何资料。
func TestScrapePersonAmbiguousMatchSkipped(t *testing.T) {
	fake := newFakeTMDB(t)
	scraper, st, _ := newTestScraper(t, fake, 0)
	ctx := context.Background()

	target := seedPerson(t, st, "")
	// 影片 credits 里没有这个人，搜索出现两个同名候选，作品也对不上。
	target.MovieTmdb = nil
	fake.searchResults = []SearchResult{
		{ID: 100, Name: "张三", KnownFor: []KnownForTitle{{Title: "无关电影A"}}},
		{ID: 101, Name: "张三", KnownFor: []KnownForTitle{{Title: "无关电影B"}}},
	}

	outcome, err := scraper.Scrape(ctx, target, false)
	if err != nil {
		t.Fatalf("刮削失败: %v", err)
	}
	if outcome.State != store.PersonMatchAmbiguous || outcome.Updated {
		t.Fatalf("重名应标记待确认且不写资料: %+v", outcome)
	}

	person, err := st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if person.Overview != "" || person.PrimaryImageTag != "" || len(person.ProviderIDs) != 0 {
		t.Fatalf("不确定的匹配不应写库: %+v", person)
	}
	saved, err := st.PersonScrapeTargetByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if saved.MatchState != store.PersonMatchAmbiguous {
		t.Fatalf("匹配状态未记录: %q", saved.MatchState)
	}
}

// TestScrapePersonSkipsLockedImages 验证图片锁优先：资料更新，图片不动。
func TestScrapePersonSkipsLockedImages(t *testing.T) {
	fake := newFakeTMDB(t)
	scraper, st, images := newTestScraper(t, fake, 2)
	ctx := context.Background()

	target := seedPerson(t, st, "42")
	if err := st.SetImageLocked(ctx, "p1", true); err != nil {
		t.Fatalf("加锁失败: %v", err)
	}
	outcome, err := scraper.Scrape(ctx, target, true)
	if err != nil {
		t.Fatalf("刮削失败: %v", err)
	}
	if outcome.Images != 0 {
		t.Fatalf("加锁后不应下载图片: %d", outcome.Images)
	}
	if images.HasItemImage("p1", "Primary", 0) {
		t.Error("加锁后仍然写了头像")
	}
	if person, _ := st.PersonByID(ctx, "p1"); person.Overview != "演员简介" {
		t.Fatalf("资料应正常更新: %+v", person)
	}
}
