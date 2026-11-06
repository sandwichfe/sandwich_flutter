package media

import (
	"os"
	"path/filepath"
	"testing"

	"embyx/internal/dto"
	"embyx/internal/store"
)

// 真实 NFO 常见带 UTF-8 BOM，这里一并覆盖。
const sampleMovieNFO = "\xEF\xBB\xBF" + `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  <title>阿凡达</title>
  <originaltitle>Avatar</originaltitle>
  <sorttitle>Avatar</sorttitle>
  <plot>潘多拉星球的故事</plot>
  <year>2009</year>
  <premiered>2009-12-18</premiered>
  <dateadded>2023-05-01 10:30:00</dateadded>
  <runtime>162</runtime>
  <mpaa>PG-13</mpaa>
  <genre>动作</genre>
  <genre>科幻</genre>
  <tag>3D</tag>
  <studio>20th Century Fox</studio>
  <uniqueid type="tmdb" default="true">19995</uniqueid>
  <uniqueid type="imdb">tt0499549</uniqueid>
  <director>詹姆斯·卡梅隆</director>
  <credits>詹姆斯·卡梅隆</credits>
  <actor><name>萨姆·沃辛顿</name><role>Jake Sully</role><order>0</order></actor>
  <actor><name>佐伊·索尔达娜</name><role>Neytiri</role><order>1</order></actor>
  <ratings>
    <rating name="themoviedb" max="10" default="true"><value>7.6</value><votes>12345</votes></rating>
  </ratings>
</movie>`

func TestParseNFOMovie(t *testing.T) {
	dir := t.TempDir()
	nfoPath := filepath.Join(dir, "movie.nfo")
	if err := os.WriteFile(nfoPath, []byte(sampleMovieNFO), 0o644); err != nil {
		t.Fatalf("写入 nfo 失败: %v", err)
	}

	data, err := ParseNFO(nfoPath)
	if err != nil {
		t.Fatalf("解析 nfo 失败: %v", err)
	}

	if data.Type != "movie" {
		t.Errorf("类型 = %q, 期望 movie", data.Type)
	}
	if data.Title != "阿凡达" {
		t.Errorf("标题 = %q", data.Title)
	}
	if data.Year != 2009 {
		t.Errorf("年份 = %d", data.Year)
	}
	if data.RuntimeMinutes != 162 {
		t.Errorf("时长 = %d", data.RuntimeMinutes)
	}
	if data.Rating != 7.6 {
		t.Errorf("评分 = %v", data.Rating)
	}
	if len(data.Genres) != 2 || data.Genres[0] != "动作" {
		t.Errorf("流派 = %v", data.Genres)
	}
	if len(data.Actors) != 2 || data.Actors[0].Role != "Jake Sully" {
		t.Errorf("演员 = %v", data.Actors)
	}
	if data.UniqueIDs["tmdb"] != "19995" || data.UniqueIDs["imdb"] != "tt0499549" {
		t.Errorf("外部编号 = %v", data.UniqueIDs)
	}
	if got := data.NormalizedPremiereDate(); got != "2009-12-18T00:00:00.0000000Z" {
		t.Errorf("上映日期 = %q", got)
	}
}

func TestFindNFO(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "Avatar (2009).mkv")
	if err := os.WriteFile(video, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	if got := FindNFO(video); got != "" {
		t.Errorf("无 NFO 时不应返回路径, 实际 %q", got)
	}

	movieNFO := filepath.Join(dir, "movie.nfo")
	writeFile(t, movieNFO, "<movie/>")
	if got := FindNFO(video); got != movieNFO {
		t.Errorf("应回退到 movie.nfo, 实际 %q", got)
	}

	sameNFO := filepath.Join(dir, "Avatar (2009).nfo")
	writeFile(t, sameNFO, "<movie/>")
	if got := FindNFO(video); got != sameNFO {
		t.Errorf("同名 NFO 优先级应更高, 实际 %q", got)
	}
}

func TestFindArtwork(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "Avatar (2009).mkv")
	writeFile(t, video, "x")

	writeFile(t, filepath.Join(dir, "poster.jpg"), "x")
	writeFile(t, filepath.Join(dir, "fanart.jpg"), "x")
	writeFile(t, filepath.Join(dir, "fanart1.jpg"), "x")
	writeFile(t, filepath.Join(dir, "clearlogo.png"), "x")
	writeFile(t, filepath.Join(dir, "banner.jpg"), "x")

	art := FindArtwork(video)
	if art.Primary != filepath.Join(dir, "poster.jpg") {
		t.Errorf("海报 = %q", art.Primary)
	}
	if len(art.Backdrops) != 2 {
		t.Fatalf("背景图数量 = %d, 期望 2", len(art.Backdrops))
	}
	if art.Logo != filepath.Join(dir, "clearlogo.png") {
		t.Errorf("logo = %q", art.Logo)
	}
	if art.Banner != filepath.Join(dir, "banner.jpg") {
		t.Errorf("banner = %q", art.Banner)
	}
}

func TestFindArtworkPrefersVideoNamedFile(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "Avatar (2009).mkv")
	writeFile(t, video, "x")
	writeFile(t, filepath.Join(dir, "poster.jpg"), "x")
	writeFile(t, filepath.Join(dir, "Avatar (2009)-poster.jpg"), "x")

	art := FindArtwork(video)
	if art.Primary != filepath.Join(dir, "Avatar (2009)-poster.jpg") {
		t.Errorf("应优先使用带视频名的海报, 实际 %q", art.Primary)
	}
}

func TestFindActorImages(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "Avatar (2009).mkv")
	writeFile(t, video, "x")
	writeFile(t, filepath.Join(dir, ".actors", "萨姆·沃辛顿.jpg"), "x")
	// 写真不能被当成头像。
	writeFile(t, filepath.Join(dir, ".actors", "萨姆·沃辛顿-fanart.jpg"), "x")

	images := FindActorImages(video)
	if len(images) != 1 {
		t.Fatalf("演员头像数量 = %d, 期望 1（写真不算头像）", len(images))
	}
	if _, ok := images["萨姆·沃辛顿"]; !ok {
		t.Errorf("未找到中文演员名: %v", images)
	}
}

func TestFindActorFanarts(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "Avatar (2009).mkv")
	writeFile(t, video, "x")
	actors := filepath.Join(dir, ".actors")
	writeFile(t, filepath.Join(actors, "萨姆·沃辛顿.jpg"), "x")
	writeFile(t, filepath.Join(actors, "萨姆·沃辛顿-fanart.jpg"), "x")
	writeFile(t, filepath.Join(actors, "萨姆·沃辛顿-fanart2.jpg"), "x")
	writeFile(t, filepath.Join(actors, "萨姆·沃辛顿-backdrop1.jpg"), "x")
	// 演员名自带数字与连字符时也要能正确还原。
	writeFile(t, filepath.Join(actors, "让-马克2-fanart3.png"), "x")

	fanarts := FindActorFanarts(video)
	if len(fanarts["萨姆·沃辛顿"]) != 3 {
		t.Fatalf("写真数量 = %d, 期望 3: %v", len(fanarts["萨姆·沃辛顿"]), fanarts)
	}
	// 自然序：fanart.jpg 排在 fanart2 前面。
	first := filepath.Base(fanarts["萨姆·沃辛顿"][0])
	if first != "萨姆·沃辛顿-fanart.jpg" {
		t.Errorf("写真排序不符: %v", fanarts["萨姆·沃辛顿"])
	}
	if len(fanarts["让-马克2"]) != 1 {
		t.Errorf("带数字的演员名解析失败: %v", fanarts)
	}
}

// TestBuildPeopleCarriesRelationOnly 验证 buildPeople 只带关联字段，
// 演员资料留给人物编辑接口维护，不从 NFO 写库。
func TestBuildPeopleCarriesRelationOnly(t *testing.T) {
	people := buildPeople(&NFOData{
		Actors: []NFOActor{{Name: "张三", Role: "主演", Type: "actor"}},
	})
	if len(people) != 1 {
		t.Fatalf("演员数量 = %d, 期望 1", len(people))
	}
	person := people[0]
	if person.Name != "张三" || person.Role != "主演" || person.Type != "Actor" {
		t.Fatalf("关联字段不符: %+v", person)
	}
	if person.ID == "" {
		t.Fatal("演员 ID 应由姓名派生")
	}
}

// TestParseNFOActorTypeAndSortOrder 覆盖 NFO 里与关联有关的两种扩展写法。
func TestParseNFOActorTypeAndSortOrder(t *testing.T) {
	dir := t.TempDir()
	nfoPath := filepath.Join(dir, "movie.nfo")
	content := `<movie>
  <title>测试</title>
  <actor>
    <name>张三</name>
    <role>主演</role>
    <type>Writer</type>
    <sortorder>3</sortorder>
  </actor>
</movie>`
	if err := os.WriteFile(nfoPath, []byte(content), 0o644); err != nil {
		t.Fatalf("写入 nfo 失败: %v", err)
	}

	data, err := ParseNFO(nfoPath)
	if err != nil {
		t.Fatalf("解析 nfo 失败: %v", err)
	}
	if len(data.Actors) != 1 {
		t.Fatalf("演员数量 = %d", len(data.Actors))
	}
	actor := data.Actors[0]
	if actor.Order != 3 {
		t.Errorf("sortorder 未生效: %d", actor.Order)
	}
	if actor.Type != "Writer" {
		t.Errorf("type 未生效: %q", actor.Type)
	}
}

func TestApplyNFOOverridesFileGuess(t *testing.T) {
	item := &store.Item{
		Name:         "Avatar 2009 1080p",
		SortName:     "Avatar 2009 1080p",
		RunTimeTicks: 999,
		Genres:       []string{},
		Tags:         []string{},
		People:       []dto.PersonDto{},
		ProviderIDs:  map[string]string{},
	}
	nfo := &NFOData{
		Title:          "阿凡达",
		Plot:           "剧情",
		Year:           2009,
		RuntimeMinutes: 162,
		Genres:         []string{"动作"},
		UniqueIDs:      map[string]string{"tmdb": "19995"},
		Actors:         []NFOActor{{Name: "萨姆·沃辛顿", Role: "Jake"}},
		Directors:      []string{"詹姆斯·卡梅隆"},
	}
	applyNFO(item, nfo)

	if item.Name != "阿凡达" || item.Overview != "剧情" {
		t.Errorf("基础字段未覆盖: %+v", item)
	}
	if item.ProductionYear == nil || *item.ProductionYear != 2009 {
		t.Errorf("年份未覆盖")
	}
	if item.ProviderIDs["Tmdb"] != "19995" {
		t.Errorf("外部编号 = %v", item.ProviderIDs)
	}
	if len(item.People) != 2 {
		t.Errorf("人物数量 = %d, 期望 2", len(item.People))
	}
	// ffprobe 已有真实时长时不应被 NFO 覆盖
	if item.RunTimeTicks != 999 {
		t.Errorf("时长被错误覆盖: %d", item.RunTimeTicks)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
