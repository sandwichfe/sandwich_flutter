package store

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"

	"embyx/internal/dto"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	st, err := Open(filepath.Join(t.TempDir(), "embyx.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

// movieItem 只填人物/分类相关字段，其余保持零值让 UpsertItem 走默认分支。
func movieItem(id, name string, genres, tags []string, studios []dto.NameIDPair, people []dto.PersonDto) *Item {
	return &Item{
		ID:          id,
		LibraryID:   "lib1",
		ParentID:    "lib1",
		Type:        "Movie",
		Name:        name,
		SortName:    name,
		Genres:      genres,
		Tags:        tags,
		Studios:     studios,
		People:      people,
		DateCreated: NowISO(),
	}
}

func actor(id, name string) dto.PersonDto {
	return dto.PersonDto{ID: id, Name: name, Type: "Actor", Role: "主演"}
}

// BenchmarkPersonsFromView 用 2000 部片子 / 700 位演职员验证 /Persons 的分页开销。
// 旧实现要读全表 people JSON 再在 Go 侧去重排序，数据量越大越慢；
// 这里走 persons 主表，耗时与条目数基本无关。
func BenchmarkPersonsFromView(b *testing.B) {
	st, err := Open(filepath.Join(b.TempDir(), "embyx.db"))
	if err != nil {
		b.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	ctx := context.Background()
	for i := 0; i < 2000; i++ {
		people := make([]dto.PersonDto, 0, 5)
		for offset := 0; offset < 5; offset++ {
			index := (i + offset) % 700
			people = append(people, actor(fmt.Sprintf("p%04d", index), fmt.Sprintf("演员%04d", index)))
		}
		item := movieItem(fmt.Sprintf("i%04d", i), fmt.Sprintf("片名%04d", i),
			[]string{"剧情"}, nil, nil, people)
		if err := st.UpsertItem(ctx, item); err != nil {
			b.Fatalf("写入条目失败: %v", err)
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, _, err := st.Persons(ctx, "u1", "", false, 0, 100); err != nil {
			b.Fatalf("查询人物失败: %v", err)
		}
	}
}

func TestPersonsReadsPersonsTable(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	studio := []dto.NameIDPair{{ID: "studio1", Name: "A24"}}

	items := []*Item{
		movieItem("i1", "Alpha", []string{"剧情", "科幻"}, []string{"4K"}, studio,
			[]dto.PersonDto{actor("p1", "张三"), {ID: "p2", Name: "李四", Type: "Director"}}),
		movieItem("i2", "Beta", []string{"剧情"}, []string{}, studio,
			[]dto.PersonDto{actor("p1", "张三")}),
	}
	for _, item := range items {
		if err := st.UpsertItem(ctx, item); err != nil {
			t.Fatalf("写入条目 %s 失败: %v", item.ID, err)
		}
	}

	persons, total, err := st.Persons(ctx, "u1", "", false, 0, 10)
	if err != nil {
		t.Fatalf("查询人物失败: %v", err)
	}
	if total != 2 || len(persons) != 2 {
		t.Fatalf("total=%d len=%d，期望 2 个人物", total, len(persons))
	}
	if persons[0].Name != "张三" || persons[1].Name != "李四" {
		t.Fatalf("人物排序不符合预期: %s, %s", persons[0].Name, persons[1].Name)
	}
	if count := persons[0].ChildCount; count == nil || *count != 2 {
		t.Fatalf("张三作品数 = %v，期望 2", count)
	}

	// 搜索走 SQL LIKE，不再读全表 JSON 后过滤。
	if _, total, err = st.Persons(ctx, "u1", "李", false, 0, 10); err != nil || total != 1 {
		t.Fatalf("按姓名搜索 total=%d err=%v，期望 1", total, err)
	}

	// 分页边界：startIndex 恰好等于 total 时返回空列表但总数不变。
	if list, total, err := st.Persons(ctx, "u1", "", false, 2, 10); err != nil || total != 2 || len(list) != 0 {
		t.Fatalf("越界分页 list=%d total=%d err=%v", len(list), total, err)
	}

	// 收藏过滤复用原来的语义：人物本身被收藏才出现。
	if _, err := st.SetFavorite(ctx, "u1", "p2", true); err != nil {
		t.Fatal(err)
	}
	list, total, err := st.Persons(ctx, "u1", "", true, 0, 10)
	if err != nil || total != 1 || list[0].ID != "p2" {
		t.Fatalf("收藏人物过滤失败: total=%d err=%v", total, err)
	}

	person, err := st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatalf("按 ID 查人物失败: %v", err)
	}
	if person.Name != "张三" || person.ChildCount == nil || *person.ChildCount != 2 {
		t.Fatalf("人物详情不符合预期: %+v", person)
	}
	if _, err := st.PersonByID(ctx, "missing"); err != ErrNotFound {
		t.Fatalf("不存在的人物应返回 ErrNotFound，得到 %v", err)
	}
}

// TestPersonsSortedByProfileFields 覆盖演员列表的四种排序字段。
// 资料为空的演员在任何方向都应排在最后，否则没录资料的演员会占满首屏。
func TestPersonsSortedByProfileFields(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	item := movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{
		actor("p1", "张三"),
		actor("p2", "李四"),
		actor("p3", "王五"),
	})
	if err := st.UpsertItem(ctx, item); err != nil {
		t.Fatalf("写入条目失败: %v", err)
	}
	// 张三：1990 出生 / 2010 出道 / C；李四：2000 出生 / 2015 出道 / A；王五全部留空。
	metadata := map[string]map[string]any{
		"p1": {"BirthDate": "1990-01-01", "PremiereDate": "2010-05-01", "CupSize": "C"},
		"p2": {"BirthDate": "2000-01-01", "PremiereDate": "2015-05-01", "CupSize": "A"},
		"p3": {},
	}
	for id, payload := range metadata {
		if len(payload) == 0 {
			continue
		}
		if err := st.UpdatePersonMetadata(ctx, id, payload); err != nil {
			t.Fatalf("更新人物 %s 失败: %v", id, err)
		}
	}

	names := func(sortBy, sortOrder string) []string {
		t.Helper()
		list, _, err := st.PersonsSorted(ctx, "u1", "", false, sortBy, sortOrder, 0, 10)
		if err != nil {
			t.Fatalf("%s/%s 排序失败: %v", sortBy, sortOrder, err)
		}
		result := make([]string, 0, len(list))
		for _, person := range list {
			result = append(result, person.Name)
		}
		return result
	}
	assertOrder := func(sortBy, sortOrder string, want ...string) {
		t.Helper()
		got := names(sortBy, sortOrder)
		if len(got) != len(want) {
			t.Fatalf("%s/%s 返回 %d 人，期望 %d 人: %v", sortBy, sortOrder, len(got), len(want), got)
		}
		for index := range want {
			if got[index] != want[index] {
				t.Fatalf("%s/%s 排序 = %v，期望 %v", sortBy, sortOrder, got, want)
			}
		}
	}

	// 名称：中文按字节序，与默认排序一致。
	assertOrder("SortName", "Ascending", "张三", "李四", "王五")
	// 年龄升序 = 生日降序（越年轻越靠前），资料为空的排最后。
	assertOrder("Age", "Ascending", "李四", "张三", "王五")
	assertOrder("Age", "Descending", "张三", "李四", "王五")
	// 出道日期：新出道的靠前，空值仍然垫底。
	assertOrder("PremiereDate", "Descending", "李四", "张三", "王五")
	assertOrder("PremiereDate", "Ascending", "张三", "李四", "王五")
	// 罩杯：A < C，空值排最后。
	assertOrder("CupSize", "Ascending", "李四", "张三", "王五")
	assertOrder("CupSize", "Descending", "张三", "李四", "王五")
}

func TestQueryItemsPersonAndFacetFilters(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	studio := []dto.NameIDPair{{ID: "studio1", Name: "A24"}}

	items := []*Item{
		movieItem("i1", "Alpha", []string{"剧情", "科幻"}, []string{"4K"}, studio,
			[]dto.PersonDto{actor("p1", "张三")}),
		movieItem("i2", "Beta", []string{"剧情"}, []string{"蓝光"}, studio,
			[]dto.PersonDto{actor("p1", "张三")}),
		movieItem("i3", "Gamma", []string{"动画"}, []string{}, nil, nil),
	}
	rating := 8.6
	items[2].CommunityRating = &rating
	for _, item := range items {
		if err := st.UpsertItem(ctx, item); err != nil {
			t.Fatalf("写入条目 %s 失败: %v", item.ID, err)
		}
	}

	// 用户数据：i1 看到一半，i3 已看完。
	if _, err := st.DB().Exec(
		`INSERT INTO user_data (user_id, item_id, played, playback_position_ticks) VALUES
		 ('u1', 'i1', 0, 500), ('u1', 'i3', 1, 0)`); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name  string
		query ItemQuery
		want  int
	}{
		{"按人物", ItemQuery{PersonIDs: []string{"p1"}}, 2},
		{"按流派", ItemQuery{GenreIDs: []string{"剧情"}}, 2},
		{"按标签", ItemQuery{TagIDs: []string{"4K"}}, 1},
		{"按工作室", ItemQuery{StudioIDs: []string{"studio1"}}, 2},
		{"最低评分", ItemQuery{MinCommunityRating: func() *float64 { v := 8.0; return &v }()}, 1},
		{"已观看", ItemQuery{IsPlayed: true}, 1},
		{"未观看", ItemQuery{IsUnplayed: true}, 2},
		{"可续播", ItemQuery{IsResumable: true}, 1},
	}
	for _, tc := range cases {
		tc.query.UserID = "u1"
		_, total, err := st.QueryItems(ctx, tc.query)
		if err != nil {
			t.Fatalf("%s 查询失败: %v", tc.name, err)
		}
		if total != tc.want {
			t.Errorf("%s total=%d，期望 %d", tc.name, total, tc.want)
		}
	}

	genres, err := st.Genres(ctx, "")
	if err != nil {
		t.Fatalf("聚合流派失败: %v", err)
	}
	if len(genres) != 3 {
		t.Fatalf("流派数 = %d，期望 3", len(genres))
	}
	// 中文排序由字节序决定，这里只校验计数与 Id 映射，不锁定具体顺序。
	genreCounts := make(map[string]int, len(genres))
	for _, genre := range genres {
		if genre.ID != genre.Name {
			t.Errorf("流派 Id 应等于名称，得到 id=%q name=%q", genre.ID, genre.Name)
		}
		genreCounts[genre.Name] = genre.Count
	}
	if genreCounts["剧情"] != 2 || genreCounts["科幻"] != 1 || genreCounts["动画"] != 1 {
		t.Fatalf("流派聚合结果不符合预期: %+v", genreCounts)
	}

	studios, err := st.Studios(ctx, "")
	if err != nil {
		t.Fatalf("聚合工作室失败: %v", err)
	}
	if len(studios) != 1 || studios[0].ID != "studio1" || studios[0].Count != 2 {
		t.Fatalf("工作室聚合结果不符合预期: %+v", studios)
	}

	tags, err := st.Tags(ctx, "")
	if err != nil || len(tags) != 2 {
		t.Fatalf("标签聚合失败: %+v err=%v", tags, err)
	}

	// ParentId 限定范围：另一个库的条目不应计入。
	other := movieItem("i4", "Delta", []string{"剧情"}, nil, nil, nil)
	other.LibraryID = "lib2"
	other.ParentID = "lib2"
	if err := st.UpsertItem(ctx, other); err != nil {
		t.Fatal(err)
	}
	if scoped, err := st.Genres(ctx, "lib1"); err != nil || len(scoped) != 3 {
		t.Fatalf("按库聚合流派失败: %+v err=%v", scoped, err)
	}
}

func TestDeleteItemKeepsPersons(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	for _, item := range []*Item{
		movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{actor("p1", "张三"), {ID: "p2", Name: "李四", Type: "Director"}}),
		movieItem("i2", "Beta", nil, nil, nil, []dto.PersonDto{actor("p1", "张三")}),
	} {
		if err := st.UpsertItem(ctx, item); err != nil {
			t.Fatal(err)
		}
	}

	if err := st.DeleteItems(ctx, []string{"i2"}); err != nil {
		t.Fatalf("删除条目失败: %v", err)
	}
	if _, total, err := st.Persons(ctx, "u1", "", false, 0, 10); err != nil || total != 2 {
		t.Fatalf("删除后人物 total=%d err=%v，期望 2（张三仍有 1 部作品）", total, err)
	}
	if person, err := st.PersonByID(ctx, "p1"); err != nil || *person.ChildCount != 1 {
		t.Fatalf("张三作品数应为 1: %+v err=%v", person, err)
	}

	if err := st.DeleteItems(ctx, []string{"i1"}); err != nil {
		t.Fatalf("删除条目失败: %v", err)
	}
	// 列表现在会返回没有作品的演员，只是作品数为 0……
	if _, total, err := st.Persons(ctx, "u1", "", false, 0, 10); err != nil || total != 2 {
		t.Fatalf("全部删除后列表 total=%d err=%v，期望 2（演员保留、作品数归零）", total, err)
	}
	// ……演员主表与关联表的行为是：演员留着、关联清空。
	var persons, links int
	if err := st.DB().QueryRow(`SELECT COUNT(*) FROM persons`).Scan(&persons); err != nil {
		t.Fatal(err)
	}
	if err := st.DB().QueryRow(`SELECT COUNT(*) FROM item_people`).Scan(&links); err != nil {
		t.Fatal(err)
	}
	if persons != 2 || links != 0 {
		t.Fatalf("演员行=%d 关联行=%d，期望 2 / 0（删片不删演员）", persons, links)
	}
	// 演员详情仍然可查，只是作品数归零。
	if person, err := st.PersonByID(ctx, "p1"); err != nil || *person.ChildCount != 0 {
		t.Fatalf("删除后仍应能查到张三且作品数为 0: %+v err=%v", person, err)
	}
}

// TestScanCreatesPersonThenOnlyLinks 验证扫描的两条分支：
// 演员表里没有这个人就新增一行，已经有了就只加一条影片关联（不重复建行）。
func TestScanCreatesPersonThenOnlyLinks(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	counts := func() (persons, links int) {
		t.Helper()
		if err := st.DB().QueryRow(`SELECT COUNT(*) FROM persons`).Scan(&persons); err != nil {
			t.Fatal(err)
		}
		if err := st.DB().QueryRow(`SELECT COUNT(*) FROM item_people`).Scan(&links); err != nil {
			t.Fatal(err)
		}
		return persons, links
	}

	// 第一部片：演员表里没有张三 → 新增演员 + 一条关联。
	if err := st.UpsertItem(ctx, movieItem("i1", "Alpha", nil, nil, nil,
		[]dto.PersonDto{actor("p1", "张三")})); err != nil {
		t.Fatal(err)
	}
	if persons, links := counts(); persons != 1 || links != 1 {
		t.Fatalf("首次入库 演员=%d 关联=%d，期望 1 / 1", persons, links)
	}

	// 第二部片：张三已存在 → 只加一条影片关联。
	if err := st.UpsertItem(ctx, movieItem("i2", "Beta", nil, nil, nil,
		[]dto.PersonDto{actor("p1", "张三")})); err != nil {
		t.Fatal(err)
	}
	if persons, links := counts(); persons != 1 || links != 2 {
		t.Fatalf("再次入库 演员=%d 关联=%d，期望 1 / 2（只加关联）", persons, links)
	}
	if person, err := st.PersonByID(ctx, "p1"); err != nil || *person.ChildCount != 2 {
		t.Fatalf("张三作品数应为 2: %+v err=%v", person, err)
	}

	// 同一部片重复扫描不应叠加关联。
	if err := st.UpsertItem(ctx, movieItem("i2", "Beta", nil, nil, nil,
		[]dto.PersonDto{actor("p1", "张三")})); err != nil {
		t.Fatal(err)
	}
	if persons, links := counts(); persons != 1 || links != 2 {
		t.Fatalf("重复扫描 演员=%d 关联=%d，期望 1 / 2", persons, links)
	}

	// 同一条目里导演 + 演员是两条关联，但演员仍然只有一行。
	if err := st.UpsertItem(ctx, movieItem("i3", "Gamma", nil, nil, nil, []dto.PersonDto{
		{ID: "p1", Name: "张三", Type: "Director"},
		actor("p1", "张三"),
	})); err != nil {
		t.Fatal(err)
	}
	if persons, links := counts(); persons != 1 || links != 4 {
		t.Fatalf("导演兼演员 演员=%d 关联=%d，期望 1 / 4", persons, links)
	}
}

// TestScanOnlyUpdatesItemPeople 验证入库只维护演员关联与本地图片：
// 演员资料（生日/简介/性别/外部编号）既不会被扫描写入，也不会被重扫覆盖。
func TestScanOnlyUpdatesItemPeople(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	// 扫描阶段能提供的就是姓名、角色与本地 .actors 图片。
	person := actor("p1", "张三")
	person.PrimaryImageTag = "tag-1"
	person.BackdropImageTags = []string{"bd-1", "bd-2"}
	if err := st.UpsertItem(ctx, movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{person})); err != nil {
		t.Fatal(err)
	}

	got, err := st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatalf("查询演员失败: %v", err)
	}
	if got.PrimaryImageTag != "tag-1" || len(got.BackdropImageTags) != 2 {
		t.Fatalf("本地图片应随入库写入: 头像=%q 写真=%v", got.PrimaryImageTag, got.BackdropImageTags)
	}
	if got.BirthDate != "" || got.PremiereDate != "" || got.Gender != "" ||
		got.CupSize != "" || got.Overview != "" || len(got.ProviderIDs) != 0 {
		t.Fatalf("演员资料不应由扫描写入: %+v", got)
	}

	// 资料由编辑接口维护。
	if err := st.UpdatePersonMetadata(ctx, "p1", map[string]any{
		"BirthDate":   "1985-06-01",
		"Overview":    "演员介绍",
		"Gender":      "Female",
		"ProviderIds": map[string]any{"Tmdb": "123"},
	}); err != nil {
		t.Fatal(err)
	}

	// 另一部片子重新入库（只有姓名）：资料与已有图片都必须保住。
	if err := st.UpsertItem(ctx, movieItem("i2", "Beta", nil, nil, nil,
		[]dto.PersonDto{actor("p1", "张三")})); err != nil {
		t.Fatal(err)
	}
	got, err = st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if got.BirthDate != "1985-06-01" || got.Overview != "演员介绍" ||
		got.Gender != "Female" || got.ProviderIDs["Tmdb"] != "123" {
		t.Fatalf("扫描不应覆盖演员资料: %+v", got)
	}
	if got.PrimaryImageTag != "tag-1" || len(got.BackdropImageTags) != 2 {
		t.Fatalf("无图条目不应擦掉已有图片: %+v", got)
	}
	if count := got.ChildCount; count == nil || *count != 2 {
		t.Fatalf("作品数应为 2: %v", count)
	}

	// 上传/删除图片后，标记要能回写演员主表。
	if err := st.SetPersonImageTag(ctx, "p1", "Backdrop", 2, "bd-3"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetPersonImageTag(ctx, "p1", "Primary", 0, "tag-2"); err != nil {
		t.Fatal(err)
	}
	if got, err = st.PersonByID(ctx, "p1"); err != nil || got.PrimaryImageTag != "tag-2" || len(got.BackdropImageTags) != 3 {
		t.Fatalf("图片标记回写失败: %+v err=%v", got, err)
	}
	// 非演员实体（媒体库等）不应报错。
	if err := st.SetPersonImageTag(ctx, "lib1", "Primary", 0, "x"); err != nil {
		t.Fatalf("非演员实体应静默跳过: %v", err)
	}
}

// TestUpdatePersonMetadata 验证演员信息的可编辑字段，以及改名后关联影片跟随。
func TestUpdatePersonMetadata(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	if err := st.UpsertItem(ctx, movieItem("i1", "Alpha", nil, nil, nil,
		[]dto.PersonDto{actor("p1", "张三")})); err != nil {
		t.Fatal(err)
	}

	if err := st.UpdatePersonMetadata(ctx, "p1", map[string]any{
		"Name":         "张三丰",
		"Overview":     "演员介绍",
		"BirthDate":    "1980-02-03",
		"PremiereDate": "2001-01-01",
		"Gender":       "Male",
		"CupSize":      "B",
		"ProviderIds":  map[string]any{"Tmdb": 42, "Imdb": "nm1"},
	}); err != nil {
		t.Fatalf("更新演员信息失败: %v", err)
	}

	person, err := st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if person.Name != "张三丰" || person.SortName != "张三丰" {
		t.Fatalf("改名后姓名/排序名不符: %+v", person)
	}
	if person.Overview != "演员介绍" || person.BirthDate != "1980-02-03" ||
		person.PremiereDate != "2001-01-01" || person.Gender != "Male" || person.CupSize != "B" {
		t.Fatalf("演员字段未更新: %+v", person)
	}
	if person.ProviderIDs["Tmdb"] != "42" || person.ProviderIDs["Imdb"] != "nm1" {
		t.Fatalf("演员外部编号未更新: %v", person.ProviderIDs)
	}

	// 详情页演员表取自主表，改名与作品数都不受影响。
	detail, err := st.GetItem(ctx, "u1", "i1")
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.People) != 1 || detail.People[0].Name != "张三丰" {
		t.Fatalf("关联影片演员表未跟随改名: %+v", detail.People)
	}
}

// TestPersonInfoUpdatedByRescan 验证重复入库时演员信息会被更新，
// 且空头像不会擦掉已导入的头像。
func TestPersonInfoUpdatedByRescan(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	withImage := actor("p1", "张三")
	withImage.PrimaryImageTag = "tag-v1"
	if err := st.UpsertItem(ctx, movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{withImage})); err != nil {
		t.Fatal(err)
	}

	noImage := actor("p1", "张三")
	if err := st.UpsertItem(ctx, movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{noImage})); err != nil {
		t.Fatal(err)
	}
	person, err := st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if person.PrimaryImageTag != "tag-v1" {
		t.Fatalf("空头像不应覆盖已有头像，得到 %q", person.PrimaryImageTag)
	}

	withNewImage := actor("p1", "张三")
	withNewImage.PrimaryImageTag = "tag-v2"
	if err := st.UpsertItem(ctx, movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{withNewImage})); err != nil {
		t.Fatal(err)
	}
	if person, err = st.PersonByID(ctx, "p1"); err != nil || person.PrimaryImageTag != "tag-v2" {
		t.Fatalf("新头像应写入演员主表: %+v err=%v", person, err)
	}

	// 条目详情里的演员信息取自主表：演员改名后立刻反映到关联影片上。
	if _, err := st.DB().Exec(`UPDATE persons SET name = ? WHERE person_id = ?`, "张三丰", "p1"); err != nil {
		t.Fatal(err)
	}
	detail, err := st.GetItem(ctx, "u1", "i1")
	if err != nil {
		t.Fatalf("查询条目失败: %v", err)
	}
	if len(detail.People) != 1 || detail.People[0].Name != "张三丰" {
		t.Fatalf("详情演员应来自 persons 主表: %+v", detail.People)
	}
}
