package metadata

import (
	"context"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// personSourceMaxBodyBytes 防御异常响应：档案页正常在几百 KB 以内。
	personSourceMaxBodyBytes = 4 << 20
	// personSourceMaxImageBytes 与 TMDB 图片上限保持一致。
	personSourceMaxImageBytes = 20 << 20
	personSourceTimeout       = 25 * time.Second
	// personSourceDefaultUA 有些站点没有 UA 会直接返回 403。
	personSourceDefaultUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

// personSourceClient 是档案站与图片来源共用的 HTTP 客户端：
// 每个站点独立限速，避免并发刮削把对方站点打到封 IP。
type personSourceClient struct {
	name      string
	http      *http.Client
	userAgent string

	mu          sync.Mutex
	lastRequest time.Time
	minInterval time.Duration
}

func newPersonSourceClient(name, proxy, userAgent string, perSecond int) (*personSourceClient, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if value := strings.TrimSpace(proxy); value != "" {
		parsed, err := url.Parse(value)
		if err != nil {
			return nil, fmt.Errorf("档案站代理地址无效: %w", err)
		}
		transport.Proxy = http.ProxyURL(parsed)
	}
	if perSecond <= 0 {
		perSecond = 1
	}
	if perSecond > 5 {
		perSecond = 5
	}
	if strings.TrimSpace(userAgent) == "" {
		userAgent = personSourceDefaultUA
	}
	return &personSourceClient{
		name:        name,
		http:        &http.Client{Timeout: personSourceTimeout, Transport: transport},
		userAgent:   strings.TrimSpace(userAgent),
		minInterval: time.Second / time.Duration(perSecond),
	}, nil
}

// wait 按最小间隔排队，串行任务下等价于「每次请求间隔 ≥ 1/速率」。
func (c *personSourceClient) wait(ctx context.Context) error {
	c.mu.Lock()
	elapsed := time.Since(c.lastRequest)
	delay := c.minInterval - elapsed
	if delay < 0 {
		delay = 0
	}
	c.lastRequest = time.Now().Add(delay)
	c.mu.Unlock()
	if delay <= 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// get 拉取一个 HTML 页面并返回文本。
func (c *personSourceClient) get(ctx context.Context, rawURL string) (string, error) {
	if err := c.wait(ctx); err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", c.userAgent)
	request.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	request.Header.Set("Accept-Language", "ja,en-US;q=0.8,en;q=0.7,zh-CN;q=0.6")

	response, err := c.http.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s 返回状态码 %d", c.name, response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, personSourceMaxBodyBytes))
	if err != nil {
		return "", err
	}
	// 日文老站点可能还是 EUC-JP，不做转码直接按 UTF-8 解析会得到乱码，
	// 与其写进库不如明确失败，日志里能看出是编码问题。
	if charset := detectCharset(response.Header.Get("Content-Type"), raw); charset != "" &&
		!strings.EqualFold(charset, "utf-8") && !strings.EqualFold(charset, "utf8") {
		return "", fmt.Errorf("%s 页面编码为 %s，暂不支持", c.name, charset)
	}
	return string(raw), nil
}

// download 下载图片原始字节，供头像落盘使用。
func (c *personSourceClient) download(ctx context.Context, rawURL string) ([]byte, error) {
	if err := c.wait(ctx); err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", c.userAgent)
	request.Header.Set("Referer", rawURL)
	response, err := c.http.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s 图片返回状态码 %d", c.name, response.StatusCode)
	}
	return io.ReadAll(io.LimitReader(response.Body, personSourceMaxImageBytes))
}

// detectCharset 先从响应头找 charset，找不到再看前 2KB 的 meta 声明。
func detectCharset(contentType string, body []byte) string {
	if index := strings.Index(strings.ToLower(contentType), "charset="); index >= 0 {
		value := strings.TrimSpace(contentType[index+len("charset="):])
		if end := strings.IndexAny(value, ";,"); end >= 0 {
			value = value[:end]
		}
		return strings.Trim(strings.TrimSpace(value), `"'`)
	}
	head := body
	if len(head) > 2048 {
		head = head[:2048]
	}
	match := charsetPattern.FindSubmatch(head)
	if len(match) >= 2 {
		return strings.ToLower(string(match[1]))
	}
	return ""
}

var charsetPattern = regexp.MustCompile(`(?i)charset=["']?([a-z0-9_-]+)`)

// ---------- HTML 解析 ----------

var (
	htmlTagPattern   = regexp.MustCompile(`(?s)<[^>]*>`)
	spacePattern     = regexp.MustCompile("[\\s\u3000]+")
	lineBreakPattern = regexp.MustCompile(`(?i)<(?:br\s*/?|/tr|/div|/p|/li|/dd|/td|/h[1-6])\s*>`)
	thTdPattern      = regexp.MustCompile(`(?is)<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>`)
	dtDdPattern      = regexp.MustCompile(`(?is)<dt[^>]*>(.*?)</dt>\s*<dd[^>]*>(.*?)</dd>`)
	labelLinePattern = regexp.MustCompile(`^([^:：]{1,24})[:：]\s*(.+)$`)
)

// htmlText 去掉标签、还原实体、压掉多余空白。
func htmlText(fragment string) string {
	text := htmlTagPattern.ReplaceAllString(fragment, " ")
	text = html.UnescapeString(text)
	return strings.TrimSpace(spacePattern.ReplaceAllString(text, " "))
}

// htmlLabelValues 把页面里的「标签 → 值」抽成 map，兼容三种常见写法：
// th/td 表格、dt/dd 列表、以及 "Height: 160cm" 这种纯文本行。
func htmlLabelValues(page string) map[string]string {
	values := make(map[string]string, 16)
	put := func(label, value string) {
		key := labelKey(htmlText(label))
		text := strings.TrimSpace(htmlText(value))
		if key == "" || text == "" {
			return
		}
		if _, exists := values[key]; !exists {
			values[key] = text
		}
	}
	for _, match := range thTdPattern.FindAllStringSubmatch(page, -1) {
		put(match[1], match[2])
	}
	for _, match := range dtDdPattern.FindAllStringSubmatch(page, -1) {
		put(match[1], match[2])
	}

	// 纯文本兜底：先按块级结束标签拆行，再匹配 "标签: 值"。
	text := lineBreakPattern.ReplaceAllString(page, "\n")
	text = html.UnescapeString(htmlTagPattern.ReplaceAllString(text, " "))
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(spacePattern.ReplaceAllString(line, " "))
		if line == "" || len(line) > 300 {
			continue
		}
		match := labelLinePattern.FindStringSubmatch(line)
		if len(match) < 3 {
			continue
		}
		put(match[1], match[2])
	}
	return values
}

// labelKey 统一标签写法：小写、去掉空格与全角括号里的补充说明。
func labelKey(label string) string {
	label = strings.ToLower(strings.TrimSpace(label))
	label = strings.TrimSuffix(label, "：")
	label = strings.TrimSpace(strings.Trim(label, "・:："))
	return spacePattern.ReplaceAllString(label, "")
}

// labelValue 按候选标签依次查找，返回第一个非空值。
func labelValue(values map[string]string, labels ...string) string {
	for _, label := range labels {
		if value := values[labelKey(label)]; value != "" {
			return value
		}
	}
	return ""
}

// htmlMetaContent 读取 <meta property/name="..."> 的 content，两种属性顺序都兼容。
func htmlMetaContent(page, property string) string {
	quoted := regexp.QuoteMeta(property)
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`(?is)<meta[^>]+(?:property|name)\s*=\s*["']` + quoted + `["'][^>]*content\s*=\s*["']([^"']+)["']`),
		regexp.MustCompile(`(?is)<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*(?:property|name)\s*=\s*["']` + quoted + `["']`),
	}
	for _, pattern := range patterns {
		if match := pattern.FindStringSubmatch(page); len(match) >= 2 {
			if value := strings.TrimSpace(html.UnescapeString(match[1])); value != "" {
				return value
			}
		}
	}
	return ""
}

// htmlHeading 取第一个 h1/h2 的文本，用作演员名。
func htmlHeading(page string) string {
	match := regexp.MustCompile(`(?is)<h[12][^>]*>(.*?)</h[12]>`).FindStringSubmatch(page)
	if len(match) < 2 {
		return ""
	}
	return htmlText(match[1])
}

// htmlTitle 取 <title> 文本，作为名字的兜底来源。
func htmlTitle(page string) string {
	match := regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`).FindStringSubmatch(page)
	if len(match) < 2 {
		return ""
	}
	return htmlText(match[1])
}

// absoluteURL 把相对链接补成绝对地址。
func absoluteURL(baseURL, href string) string {
	href = strings.TrimSpace(href)
	if href == "" {
		return ""
	}
	base, err := url.Parse(baseURL)
	if err != nil {
		return href
	}
	reference, err := url.Parse(href)
	if err != nil {
		return href
	}
	return base.ResolveReference(reference).String()
}

var anchorPattern = regexp.MustCompile(`(?is)<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>`)

// extractAnchors 抓出符合链接规则的候选（演员搜索结果）。
// 名字优先取链接文字，只有图片时退回 alt。
func extractAnchors(page, pageURL string, hrefPattern *regexp.Regexp) []PersonCandidate {
	candidates := make([]PersonCandidate, 0, 16)
	seen := make(map[string]bool, 16)
	for _, match := range anchorPattern.FindAllStringSubmatch(page, -1) {
		href := strings.TrimSpace(html.UnescapeString(match[1]))
		if href == "" || strings.HasPrefix(href, "#") {
			continue
		}
		if hrefPattern != nil && !hrefPattern.MatchString(href) {
			continue
		}
		name := htmlText(match[2])
		if name == "" {
			name = attrValue(match[2], "alt")
		}
		name = cleanPersonDisplayName(name)
		absolute := absoluteURL(pageURL, href)
		if name == "" || absolute == "" || seen[absolute] {
			continue
		}
		seen[absolute] = true
		candidates = append(candidates, PersonCandidate{Name: name, URL: absolute})
	}
	return candidates
}

// attrValue 读取 HTML 片段里某个属性的值（alt / src 等）。
func attrValue(fragment, attribute string) string {
	pattern := regexp.MustCompile(`(?is)\b` + regexp.QuoteMeta(attribute) + `\s*=\s*["']([^"']*)["']`)
	if match := pattern.FindStringSubmatch(fragment); len(match) >= 2 {
		return strings.TrimSpace(html.UnescapeString(match[1]))
	}
	return ""
}

var imageTagPattern = regexp.MustCompile(`(?is)<img[^>]*>`)

// firstImageWithHint 按 src 关键字挑一张图，避免把广告位当成头像。
func firstImageWithHint(page string, hints ...string) string {
	for _, tag := range imageTagPattern.FindAllString(page, -1) {
		src := attrValue(tag, "src")
		if src == "" {
			continue
		}
		lower := strings.ToLower(src)
		for _, hint := range hints {
			if strings.Contains(lower, strings.ToLower(hint)) {
				return src
			}
		}
	}
	return ""
}

// ---------- 字段归一化 ----------

var dateNumberPattern = regexp.MustCompile(`\d+`)

// normalizeDate 把 1993年8月16日 / 1993/8/16 / 1993.8.16 统一成 1993-08-16。
// 只有年份时补 01-01，保证数据库里能按日期排序。
func normalizeDate(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return ""
	}
	parts := dateNumberPattern.FindAllString(value, 3)
	if len(parts) == 0 {
		return ""
	}
	year, err := strconv.Atoi(parts[0])
	if err != nil || year < 1900 || year > 2100 {
		return ""
	}
	month, day := 1, 1
	if len(parts) > 1 {
		if parsed, err := strconv.Atoi(parts[1]); err == nil && parsed >= 1 && parsed <= 12 {
			month = parsed
		}
	}
	if len(parts) > 2 {
		if parsed, err := strconv.Atoi(parts[2]); err == nil && parsed >= 1 && parsed <= 31 {
			day = parsed
		}
	}
	return fmt.Sprintf("%04d-%02d-%02d", year, month, day)
}

var heightPattern = regexp.MustCompile(`\d{3}`)

// normalizeHeight 统一成 "160cm"；数值明显不合理时丢弃，避免写入 0cm。
func normalizeHeight(raw string) string {
	digits := heightPattern.FindString(raw)
	if digits == "" {
		return ""
	}
	value, err := strconv.Atoi(digits)
	if err != nil || value < 120 || value > 220 {
		return ""
	}
	return strconv.Itoa(value) + "cm"
}

var cupPattern = regexp.MustCompile(`(?i)([A-K])`)

// normalizeCup 从 "Dカップ" / "D cup" / "D" 里取罩杯字母。
func normalizeCup(raw string) string {
	match := cupPattern.FindStringSubmatch(strings.TrimSpace(raw))
	if len(match) < 2 {
		return ""
	}
	return strings.ToUpper(match[1])
}

var (
	bustPattern      = regexp.MustCompile(`(?i)\bB\s*[:：]?\s*(\d{2,3})`)
	waistPattern     = regexp.MustCompile(`(?i)\bW\s*[:：]?\s*(\d{2,3})`)
	hipPattern       = regexp.MustCompile(`(?i)\bH\s*[:：]?\s*(\d{2,3})`)
	threeSizePattern = regexp.MustCompile(`(\d{2,3})\s*[-/／]\s*(\d{2,3})\s*[-/／]\s*(\d{2,3})`)
)

// normalizeMeasurements 统一成 "B88 / W58 / H88"。
func normalizeMeasurements(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return ""
	}
	bust := firstGroup(bustPattern, value)
	waist := firstGroup(waistPattern, value)
	hip := firstGroup(hipPattern, value)
	if bust == "" && waist == "" && hip == "" {
		if match := threeSizePattern.FindStringSubmatch(value); len(match) >= 4 {
			bust, waist, hip = match[1], match[2], match[3]
		}
	}
	parts := make([]string, 0, 3)
	if bust != "" {
		parts = append(parts, "B"+bust)
	}
	if waist != "" {
		parts = append(parts, "W"+waist)
	}
	if hip != "" {
		parts = append(parts, "H"+hip)
	}
	return strings.Join(parts, " / ")
}

func firstGroup(pattern *regexp.Regexp, value string) string {
	if match := pattern.FindStringSubmatch(value); len(match) >= 2 {
		return match[1]
	}
	return ""
}

// splitAliases 拆分多别名写法（、，/ ／ ; ；）。
func splitAliases(raw string) []string {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		switch r {
		case '、', '，', ',', '/', '／', ';', '；', '|':
			return true
		}
		return false
	})
	aliases := make([]string, 0, len(fields))
	seen := make(map[string]bool, len(fields))
	for _, field := range fields {
		value := strings.TrimSpace(field)
		key := normalizePersonName(value)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		aliases = append(aliases, value)
	}
	return aliases
}

// cleanPersonDisplayName 去掉站点标题里的后缀（"三上悠亜 - みんなのAV.com"）。
func cleanPersonDisplayName(name string) string {
	value := strings.TrimSpace(name)
	for _, separator := range []string{" - ", "｜", " | "} {
		if index := strings.Index(value, separator); index > 0 {
			value = value[:index]
		}
	}
	return strings.TrimSpace(value)
}
