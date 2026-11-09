package metadata

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"embyx/internal/media"
	"embyx/internal/store"
)

// testPNG 生成一张最小合法 PNG，供图片下载用例断言落盘。
func testPNG(t *testing.T) []byte {
	t.Helper()
	buffer := &bytes.Buffer{}
	if err := png.Encode(buffer, image.NewRGBA(image.Rect(0, 0, 4, 4))); err != nil {
		t.Fatalf("生成测试图片失败: %v", err)
	}
	return buffer.Bytes()
}

// TestNormalizePersonFields 覆盖不同站点的字段写法归一化。
func TestNormalizePersonFields(t *testing.T) {
	cases := []struct {
		name string
		got  string
		want string
	}{
		{"生日", normalizeDate("1993年8月16日"), "1993-08-16"},
		{"生日-斜杠", normalizeDate("1993/8/6"), "1993-08-06"},
		{"生日-只有年份", normalizeDate("1993年"), "1993-01-01"},
		{"身高", normalizeHeight("159cm"), "159cm"},
		{"身高-不合理", normalizeHeight("59cm"), ""},
		{"罩杯", normalizeCup("Dカップ"), "D"},
		{"三围", normalizeMeasurements("B84 / W58 / H88"), "B84 / W58 / H88"},
		{"三围-短横线", normalizeMeasurements("84-58-88"), "B84 / W58 / H88"},
		{"别名拆分", strings.Join(splitAliases("三上悠亜、みかみゆあ/ゆあ"), ","), "三上悠亜,みかみゆあ,ゆあ"},
	}
	for _, testCase := range cases {
		if testCase.got != testCase.want {
			t.Errorf("%s: 得到 %q, 期望 %q", testCase.name, testCase.got, testCase.want)
		}
	}
}

// TestHTMLLabelValuesSupportsTablesAndTextLines 验证两种常见页面结构都能取到标签值。
func TestHTMLLabelValuesSupportsTablesAndTextLines(t *testing.T) {
	page := `<html><body>
		<table>
			<tr><th>生年月日</th><td>1993年8月16日</td></tr>
			<tr><th>身長</th><td>159cm</td></tr>
		</table>
		<div><strong>Measurements:</strong> B84 / W58 / H88</div>
		<p>Cup Size: D</p>
	</body></html>`
	values := htmlLabelValues(page)
	if got := labelValue(values, "生年月日"); got != "1993年8月16日" {
		t.Errorf("生年月日 = %q", got)
	}
	if got := labelValue(values, "身長"); got != "159cm" {
		t.Errorf("身長 = %q", got)
	}
	if got := labelValue(values, "Cup Size"); got != "D" {
		t.Errorf("Cup Size = %q", got)
	}
	if got := normalizeMeasurements(labelValue(values, "Measurements")); got != "B84 / W58 / H88" {
		t.Errorf("Measurements = %q", got)
	}
}

// TestMergePersonProfilesKeepsPriority 验证字段级合并：高优先级来源的非空值优先，
// 缺的字段由低优先级来源补齐，ProviderIDs 全部保留。
func TestMergePersonProfilesKeepsPriority(t *testing.T) {
	merged := mergePersonProfiles([]*PersonProfile{
		{
			Source:      "MinnanoAV",
			Name:        "三上悠亜",
			CupSize:     "D",
			BodyHeight:  "159cm",
			Aliases:     []string{"みかみゆあ"},
			ProviderIDs: map[string]string{"MinnanoAV": "1"},
		},
		{
			Source:       "JavModel",
			Name:         "三上悠亜",
			CupSize:      "E",
			Measurements: "B84 / W58 / H88",
			ProviderIDs:  map[string]string{"Javmodel": "mikami"},
		},
	})
	if merged == nil {
		t.Fatal("合并结果为空")
	}
	if merged.CupSize != "D" {
		t.Errorf("罩杯应按优先级取 D，实际 %q", merged.CupSize)
	}
	if merged.BodyHeight != "159cm" || merged.Measurements != "B84 / W58 / H88" {
		t.Errorf("兜底字段未补齐: %+v", merged)
	}
	if merged.ProviderIDs["MinnanoAV"] != "1" || merged.ProviderIDs["Javmodel"] != "mikami" {
		t.Errorf("外部编号未合并: %v", merged.ProviderIDs)
	}
	// 合并结果会带上来源给的名字本身，方便下次用任一个名字继续匹配。
	if len(merged.Aliases) != 2 || merged.Aliases[0] != "三上悠亜" || merged.Aliases[1] != "みかみゆあ" {
		t.Errorf("别名合并异常: %v", merged.Aliases)
	}
}

// TestScrapePersonUsesAVSources 覆盖完整链路：
// MinnanoAV 搜索 + 详情解析 → JavModel 兜底补字段 → 写库 + 头像落盘。
func TestScrapePersonUsesAVSources(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "embyx.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	images := media.NewImageStore(filepath.Join(t.TempDir(), "images"))
	target := seedPerson(t, st, "")

	imageBytes := testPNG(t)
	minnano := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/search_result.php"):
			_, _ = w.Write([]byte(`<html><body>
				<a href="actress1.html">张三</a>
			</body></html>`))
		case r.URL.Path == "/actress1.html":
			_, _ = w.Write([]byte(`<html><head>
				<meta property="og:image" content="/img.jpg">
				</head><body>
				<h1>张三</h1>
				<table>
					<tr><th>生年月日</th><td>1993年8月16日</td></tr>
					<tr><th>身長</th><td>159cm</td></tr>
					<tr><th>スリーサイズ</th><td>B84 / W58 / H88</td></tr>
					<tr><th>カップ</th><td>D</td></tr>
					<tr><th>デビュー</th><td>2015年</td></tr>
					<tr><th>別名</th><td>みかみゆあ、ゆあ</td></tr>
				</table>
			</body></html>`))
		default:
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(imageBytes)
		}
	}))
	t.Cleanup(minnano.Close)

	javModel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/":
			_, _ = w.Write([]byte(`<html><body><a href="/jav/zhangsan/">张三</a></body></html>`))
		case r.URL.Path == "/jav/zhangsan/":
			_, _ = w.Write([]byte(`<html><body>
				<h1>张三</h1>
				<p>Cup Size: E</p>
				<p>Measurements: 84-58-88</p>
			</body></html>`))
		default:
			_, _ = w.Write([]byte(`<html><body></body></html>`))
		}
	}))
	t.Cleanup(javModel.Close)

	minnanoSource, err := NewMinnanoAVSource(minnano.URL, "", "", 5)
	if err != nil {
		t.Fatal(err)
	}
	javModelSource, err := NewJavModelSource(javModel.URL, "", "", 5)
	if err != nil {
		t.Fatal(err)
	}

	scraper := NewPersonScraper(st, images, nil, 0)
	scraper.AddSource(javModelSource)
	scraper.AddSource(minnanoSource)

	outcome, err := scraper.Scrape(context.Background(), target, false)
	if err != nil {
		t.Fatalf("刮削失败: %v", err)
	}
	if outcome.State != store.PersonMatchMatched || !outcome.Updated {
		t.Fatalf("刮削结果不符: %+v", outcome)
	}
	if outcome.Images != 1 {
		t.Errorf("应下载 1 张头像，实际 %d", outcome.Images)
	}

	person, err := st.PersonByID(context.Background(), "p1")
	if err != nil {
		t.Fatal(err)
	}
	if person.BirthDate != "1993-08-16" || person.PremiereDate != "2015-01-01" {
		t.Errorf("生日/出道日未写入: %+v", person)
	}
	if person.BodyHeight != "159cm" || person.CupSize != "D" {
		t.Errorf("身高/罩杯未按优先级写入: %+v", person)
	}
	if person.Measurements != "B84 / W58 / H88" {
		t.Errorf("三围 = %q", person.Measurements)
	}
	if person.Gender != "Female" {
		t.Errorf("性别 = %q", person.Gender)
	}
	if person.ProviderIDs["MinnanoAV"] != "1" || person.ProviderIDs["Javmodel"] != "zhangsan" {
		t.Errorf("外部编号未写入: %v", person.ProviderIDs)
	}
	if len(person.Aliases) < 2 {
		t.Errorf("别名未写入: %v", person.Aliases)
	}
	if !images.HasItemImage("p1", "Primary", 0) {
		t.Error("头像文件缺失")
	}
}

// TestScrapePersonAmbiguousSourceSkipsWrite 验证来源给了多个同名候选时不写任何字段。
func TestScrapePersonAmbiguousSourceSkipsWrite(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "embyx.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	images := media.NewImageStore(filepath.Join(t.TempDir(), "images"))
	target := seedPerson(t, st, "")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/search_result.php":
			_, _ = w.Write([]byte(`<html><body>
				<a href="actress1.html">张三</a>
				<a href="actress2.html">张三</a>
			</body></html>`))
		default:
			_, _ = w.Write([]byte(`<html><body><h1>张三</h1></body></html>`))
		}
	}))
	t.Cleanup(server.Close)

	source, err := NewMinnanoAVSource(server.URL, "", "", 5)
	if err != nil {
		t.Fatal(err)
	}
	scraper := NewPersonScraper(st, images, nil, 0)
	scraper.AddSource(source)

	outcome, err := scraper.Scrape(context.Background(), target, false)
	if err != nil {
		t.Fatalf("刮削失败: %v", err)
	}
	if outcome.State != store.PersonMatchAmbiguous || outcome.Updated {
		t.Fatalf("重名应标记待确认且不写资料: %+v", outcome)
	}
	person, err := st.PersonByID(context.Background(), "p1")
	if err != nil {
		t.Fatal(err)
	}
	if person.BodyHeight != "" || person.CupSize != "" || len(person.ProviderIDs) != 0 {
		t.Fatalf("不确定的匹配不应写库: %+v", person)
	}
}
