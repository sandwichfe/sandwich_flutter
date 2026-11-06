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
	// 列表不再展示没有作品的演员……
	if _, total, err := st.Persons(ctx, "u1", "", false, 0, 10); err != nil || total != 0 {
		t.Fatalf("全部删除后列表 total=%d err=%v，期望 0", total, err)
	}
	// ……但演员主表与关联表的行为是：演员留着、关联清空。
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
