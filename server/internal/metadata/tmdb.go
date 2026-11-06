package metadata

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	tmdbBaseURL   = "https://api.themoviedb.org/3"
	tmdbImageBase = "https://image.tmdb.org/t/p"

	// tmdbDefaultRate 是默认请求速率（次/秒）。
	// TMDB 官方要求不超过 50 次/秒，默认 4 次/秒只有上限的 8%，
	// 留给图片下载与并发余量，正常刮削不会被限流或封禁。
	tmdbDefaultRate = 4

	// tmdbMaxRate 是允许配置的速率上限：再高就容易触发 429。
	tmdbMaxRate = 10

	// tmdbMaxImageBytes 防御异常响应：演员图片正常在几 MB 以内。
	tmdbMaxImageBytes = 20 << 20
)

// Client 是 TMDB v3 的最小客户端，只实现演员刮削需要的几个接口。
type Client struct {
	apiKey       string
	language     string
	baseURL      string
	imageBaseURL string
	http         *http.Client

	// 限速状态。任务本身是串行的，加锁是为了防御将来多个调用方共用同一个客户端。
	mu            sync.Mutex
	lastRequest   time.Time
	cooldownUntil time.Time
	minInterval   time.Duration
}

// NewClient 创建 TMDB 客户端。proxy 非空时所有请求走该代理（国内网络通常需要）。
func NewClient(apiKey, language, proxy string) (*Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if value := strings.TrimSpace(proxy); value != "" {
		parsed, err := url.Parse(value)
		if err != nil {
			return nil, fmt.Errorf("TMDB 代理地址无效: %w", err)
		}
		transport.Proxy = http.ProxyURL(parsed)
	}
	if strings.TrimSpace(language) == "" {
		language = "zh-CN"
	}
	return &Client{
		apiKey:       strings.TrimSpace(apiKey),
		language:     language,
		baseURL:      tmdbBaseURL,
		imageBaseURL: tmdbImageBase,
		minInterval:  time.Second / tmdbDefaultRate,
		http: &http.Client{
			Timeout:   20 * time.Second,
			Transport: transport,
		},
	}, nil
}

// SetRateLimit 调整请求速率（次/秒），超出 1~10 的范围会被夹到边界。
func (c *Client) SetRateLimit(perSecond int) {
	if perSecond <= 0 {
		perSecond = tmdbDefaultRate
	}
	if perSecond > tmdbMaxRate {
		perSecond = tmdbMaxRate
	}
	c.mu.Lock()
	c.minInterval = time.Second / time.Duration(perSecond)
	c.mu.Unlock()
}

// RateLimit 返回当前速率（次/秒），便于启动日志确认。
func (c *Client) RateLimit() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.minInterval <= 0 {
		return tmdbDefaultRate
	}
	return int(time.Second / c.minInterval)
}

// SetEndpoints 覆盖 API 与图片基址，供测试与自建反代使用。
func (c *Client) SetEndpoints(apiBase, imageBase string) {
	if value := strings.TrimRight(strings.TrimSpace(apiBase), "/"); value != "" {
		c.baseURL = value
	}
	if value := strings.TrimRight(strings.TrimSpace(imageBase), "/"); value != "" {
		c.imageBaseURL = value
	}
}

// Configured 表示 Key 是否已配置；未配置时刮削接口应直接提示用户。
func (c *Client) Configured() bool {
	return c != nil && c.apiKey != ""
}

// ---------- 响应结构 ----------

type Person struct {
	ID                 int      `json:"id"`
	Name               string   `json:"name"`
	Biography          string   `json:"biography"`
	Birthday           string   `json:"birthday"`
	Deathday           string   `json:"deathday"`
	Gender             int      `json:"gender"`
	PlaceOfBirth       string   `json:"place_of_birth"`
	ProfilePath        string   `json:"profile_path"`
	KnownForDepartment string   `json:"known_for_department"`
	AlsoKnownAs        []string `json:"also_known_as"`
	Popularity         float64  `json:"popularity"`
	Homepage           string   `json:"homepage"`
}

type PersonImages struct {
	Profiles []Image `json:"profiles"`
}

type Image struct {
	FilePath    string  `json:"file_path"`
	Width       int     `json:"width"`
	Height      int     `json:"height"`
	VoteAverage float64 `json:"vote_average"`
	VoteCount   int     `json:"vote_count"`
}

type ExternalIDs struct {
	IMDBID string `json:"imdb_id"`
}

type SearchResult struct {
	ID                 int             `json:"id"`
	Name               string          `json:"name"`
	Gender             int             `json:"gender"`
	ProfilePath        string          `json:"profile_path"`
	KnownForDepartment string          `json:"known_for_department"`
	Popularity         float64         `json:"popularity"`
	KnownFor           []KnownForTitle `json:"known_for"`
}

// KnownForTitle 只关心电影标题，用于重名时和演员的作品列表做交叉验证。
type KnownForTitle struct {
	Title       string `json:"title"`
	Name        string `json:"name"`
	MediaType   string `json:"media_type"`
	ReleaseDate string `json:"release_date"`
}

type Credit struct {
	ID         int    `json:"id"`
	Name       string `json:"name"`
	Character  string `json:"character"`
	Job        string `json:"job"`
	Department string `json:"department"`
	Order      int    `json:"order"`
}

type MovieCredits struct {
	Cast []Credit `json:"cast"`
	Crew []Credit `json:"crew"`
}

type searchResponse struct {
	Results []SearchResult `json:"results"`
}

// ---------- 接口 ----------

// Person 读取演员详情。目标语言没有简介时回退英文，避免中文库大面积空白。
func (c *Client) Person(ctx context.Context, personID string) (*Person, error) {
	var person Person
	if err := c.get(ctx, "/person/"+personID, nil, &person); err != nil {
		return nil, err
	}
	if strings.TrimSpace(person.Biography) == "" && !strings.EqualFold(c.language, "en-US") {
		var fallback Person
		if err := c.get(ctx, "/person/"+personID, url.Values{"language": {"en-US"}}, &fallback); err == nil {
			person.Biography = fallback.Biography
			if len(person.AlsoKnownAs) == 0 {
				person.AlsoKnownAs = fallback.AlsoKnownAs
			}
		}
	}
	return &person, nil
}

func (c *Client) PersonImages(ctx context.Context, personID string) (*PersonImages, error) {
	var images PersonImages
	if err := c.get(ctx, "/person/"+personID+"/images", nil, &images); err != nil {
		return nil, err
	}
	return &images, nil
}

func (c *Client) PersonExternalIDs(ctx context.Context, personID string) (*ExternalIDs, error) {
	var ids ExternalIDs
	if err := c.get(ctx, "/person/"+personID+"/external_ids", nil, &ids); err != nil {
		return nil, err
	}
	return &ids, nil
}

func (c *Client) SearchPerson(ctx context.Context, query string) ([]SearchResult, error) {
	var response searchResponse
	values := url.Values{"query": {query}, "include_adult": {"false"}}
	if err := c.get(ctx, "/search/person", values, &response); err != nil {
		return nil, err
	}
	return response.Results, nil
}

func (c *Client) MovieCredits(ctx context.Context, movieID string) (*MovieCredits, error) {
	var credits MovieCredits
	if err := c.get(ctx, "/movie/"+movieID+"/credits", nil, &credits); err != nil {
		return nil, err
	}
	return &credits, nil
}

// ImageURL 拼出可下载的图片地址；size 为空时用 w780。
func ImageURL(filePath, size string) string {
	if filePath == "" {
		return ""
	}
	if size == "" {
		size = "w780"
	}
	return tmdbImageBase + "/" + size + filePath
}

// DownloadImage 下载一张图片原图字节。
func (c *Client) DownloadImage(ctx context.Context, filePath, size string) ([]byte, error) {
	if filePath == "" {
		return nil, fmt.Errorf("图片路径为空")
	}
	if size == "" {
		size = "w780"
	}
	target := c.imageBaseURL + "/" + size + filePath
	response, err := c.do(ctx, target, nil)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	return io.ReadAll(io.LimitReader(response.Body, tmdbMaxImageBytes))
}

// get 发起 API 请求并解析 JSON，自带限速与 429/5xx 重试。
func (c *Client) get(ctx context.Context, path string, values url.Values, dst any) error {
	if !c.Configured() {
		return fmt.Errorf("未配置 TMDB API Key")
	}
	query := url.Values{}
	for key, list := range values {
		for _, value := range list {
			query.Add(key, value)
		}
	}
	if _, ok := query["language"]; !ok {
		query.Set("language", c.language)
	}
	query.Set("api_key", c.apiKey)

	response, err := c.do(ctx, c.baseURL+path+"?"+query.Encode(), nil)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return fmt.Errorf("读取 TMDB 响应失败: %w", err)
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return fmt.Errorf("解析 TMDB 响应失败: %w", err)
	}
	return nil
}

// do 是所有请求的唯一出口：串行限速 + 退避重试。
func (c *Client) do(ctx context.Context, target string, headers map[string]string) (*http.Response, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if err := c.waitTurn(ctx); err != nil {
			return nil, err
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
		if err != nil {
			return nil, err
		}
		request.Header.Set("Accept", "application/json")
		for key, value := range headers {
			request.Header.Set(key, value)
		}

		response, err := c.http.Do(request)
		if err != nil {
			lastErr = err
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			continue
		}
		if response.StatusCode == http.StatusOK {
			return response, nil
		}

		lastErr = fmt.Errorf("TMDB 返回 HTTP %d", response.StatusCode)
		// 429 / 5xx 才值得重试，其余（404、401）重试也没意义。
		retryable := response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500
		if !retryable {
			response.Body.Close()
			return nil, lastErr
		}
		delay := time.Duration(attempt+1) * time.Second
		if value := response.Header.Get("Retry-After"); value != "" {
			if seconds, err := strconv.Atoi(value); err == nil && seconds > 0 {
				delay = time.Duration(seconds) * time.Second
			}
		}
		if response.StatusCode == http.StatusTooManyRequests {
			// 被限流时让整个客户端一起冷静，而不是只等这一次重试：
			// 否则后续请求还会以原速率继续打过去，越打越久。
			log.Printf("[tmdb] 触发限流(429)，暂停 %s 后再继续", delay)
			c.coolDown(delay)
		}
		response.Body.Close()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil, lastErr
}

// waitTurn 保证两次请求之间至少间隔 minInterval，并且遵守 429 后的全局冷却。
// 循环是为了让并发调用方在别人插队后重新计算等待时间。
func (c *Client) waitTurn(ctx context.Context) error {
	for {
		c.mu.Lock()
		wait := time.Until(c.lastRequest.Add(c.minInterval))
		if cooldown := time.Until(c.cooldownUntil); cooldown > wait {
			wait = cooldown
		}
		if wait <= 0 {
			c.lastRequest = time.Now()
			c.mu.Unlock()
			return nil
		}
		c.mu.Unlock()

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
}

// coolDown 让整个客户端暂停一段时间，收到 429 时调用。
func (c *Client) coolDown(duration time.Duration) {
	if duration <= 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if until := time.Now().Add(duration); until.After(c.cooldownUntil) {
		c.cooldownUntil = until
	}
}
