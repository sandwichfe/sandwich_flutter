package store

import (
	"context"
	"fmt"
	"testing"
)

// seedItems 构造一组覆盖浏览/搜索/排序场景的条目。
func seedItems(t *testing.T, st *Store) {
	t.Helper()
	ctx := context.Background()

	year2020, year2021 := 2020, 2021
	items := []*Item{
		{
			ID: "i1", LibraryID: "lib1", ParentID: "lib1", Type: "Movie",
			Name: "Alpha", SortName: "Alpha", Overview: "太空歌剧",
			ProductionYear: &year2020, DateCreated: "2024-01-01T00:00:00.0000000Z",
		},
		{
			ID: "i2", LibraryID: "lib2", ParentID: "lib2", Type: "Movie",
			Name: "Beta", SortName: "Beta", Overview: "黑白默片",
			ProductionYear: &year2021, DateCreated: "2024-02-01T00:00:00.0000000Z",
		},
		{
			ID: "i3", LibraryID: "lib1", ParentID: "lib1", Type: "Video",
			Name: "Gamma", SortName: "Gamma", Overview: "家庭录像",
			ProductionYear: &year2020, DateCreated: "2024-03-01T00:00:00.0000000Z",
		},
	}
	for _, item := range items {
		if err := st.UpsertItem(ctx, item); err != nil {
			t.Fatalf("写入条目 %s 失败: %v", item.ID, err)
		}
	}

	// 用户数据：i2 收藏，i3 看到一半。
	if _, err := st.DB().Exec(
		`INSERT INTO user_data (user_id, item_id, is_favorite, played, playback_position_ticks) VALUES
		 ('u1', 'i2', 1, 0, 0), ('u1', 'i3', 0, 0, 500)`); err != nil {
		t.Fatalf("写入用户数据失败: %v", err)
	}
}

func TestQueryItemsFilters(t *testing.T) {
	st := openTestStore(t)
	seedItems(t, st)
	ctx := context.Background()

	cases := []struct {
		name  string
		query ItemQuery
		want  int
	}{
		{"库内浏览", ItemQuery{ParentID: "lib1"}, 2},
		{"按类型", ItemQuery{IncludeTypes: []string{"Video"}}, 1},
		{"按名称搜索", ItemQuery{SearchTerm: "beta"}, 1},
		// 搜索范围包含 overview：客户端全局搜索依赖它。
		{"按简介搜索", ItemQuery{SearchTerm: "太空"}, 1},
		{"按年份", ItemQuery{Years: []int{2020}}, 2},
		{"指定 ID", ItemQuery{ItemIDs: []string{"i1", "i3"}}, 2},
		{"排除 ID", ItemQuery{ExcludeIDs: []string{"i1"}}, 2},
		{"收藏", ItemQuery{FavoriteOnly: true}, 1},
		{"可续播", ItemQuery{OnlyResume: true}, 1},
		{"组合条件", ItemQuery{ParentID: "lib1", IncludeTypes: []string{"Movie"}, Years: []int{2020}}, 1},
		// 空搜索词不应产生 LIKE 条件，否则会排除 name 为空的条目。
		{"空搜索词", ItemQuery{SearchTerm: "   "}, 3},
	}

	for _, tc := range cases {
		tc.query.UserID = "u1"
		list, total, err := st.QueryItems(ctx, tc.query)
		if err != nil {
			t.Fatalf("%s 查询失败: %v", tc.name, err)
		}
		if total != tc.want {
			t.Errorf("%s total=%d，期望 %d", tc.name, total, tc.want)
		}
		if len(list) != tc.want {
			t.Errorf("%s 返回 %d 条，期望 %d", tc.name, len(list), tc.want)
		}
	}
}

func TestQueryItemsPagination(t *testing.T) {
	st := openTestStore(t)
	seedItems(t, st)
	ctx := context.Background()

	// Limit 缺省按 100 处理，翻页时总数与当前页长度互相独立。
	list, total, err := st.QueryItems(ctx, ItemQuery{UserID: "u1"})
	if err != nil || total != 3 || len(list) != 3 {
		t.Fatalf("默认分页 list=%d total=%d err=%v", len(list), total, err)
	}

	list, total, err = st.QueryItems(ctx, ItemQuery{UserID: "u1", SortBy: []string{"SortName"}, StartIndex: 1, Limit: 1})
	if err != nil || total != 3 || len(list) != 1 || list[0].ID != "i2" {
		t.Fatalf("第二页 list=%d total=%d err=%v", len(list), total, err)
	}

	// 越界与负数 startIndex 都按 0 处理，不能返回错误。
	if list, total, err = st.QueryItems(ctx, ItemQuery{UserID: "u1", StartIndex: 99}); err != nil || total != 3 || len(list) != 0 {
		t.Fatalf("越界分页 list=%d total=%d err=%v", len(list), total, err)
	}
	if list, _, err = st.QueryItems(ctx, ItemQuery{UserID: "u1", StartIndex: -5, Limit: 2}); err != nil || len(list) != 2 {
		t.Fatalf("负 startIndex list=%d err=%v", len(list), err)
	}
}

func TestQueryItemsSortWhitelist(t *testing.T) {
	st := openTestStore(t)
	seedItems(t, st)
	ctx := context.Background()

	list, _, err := st.QueryItems(ctx, ItemQuery{UserID: "u1", SortBy: []string{"SortName"}, SortOrder: "Descending"})
	if err != nil {
		t.Fatalf("倒序查询失败: %v", err)
	}
	got := []string{list[0].Name, list[1].Name, list[2].Name}
	want := []string{"Gamma", "Beta", "Alpha"}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("SortName 倒序结果 = %v，期望 %v", got, want)
		}
	}

	// 不在白名单里的列名直接忽略，不会拼进 SQL；全部无效时回落到 sort_name。
	if list, _, err = st.QueryItems(ctx, ItemQuery{UserID: "u1", SortBy: []string{"i.name; DROP TABLE items", "id"}}); err != nil {
		t.Fatalf("非法排序列查询失败: %v", err)
	}
	if list[0].Name != "Alpha" {
		t.Fatalf("非法排序列应回落到 sort_name，得到 %s", list[0].Name)
	}
	// 表还在（上一条如果拼了 SQL 会直接报错或删表）。
	if _, _, err = st.QueryItems(ctx, ItemQuery{UserID: "u1"}); err != nil {
		t.Fatalf("非法排序后查询失败: %v", err)
	}

	// 排序值相同时追加主键兜底，保证分页稳定。
	first, _, err := st.QueryItems(ctx, ItemQuery{UserID: "u1", SortBy: []string{"ProductionYear"}, Limit: 2})
	if err != nil {
		t.Fatalf("按年份排序失败: %v", err)
	}
	if first[0].ID != "i1" || first[1].ID != "i3" {
		t.Fatalf("同值排序未按 id 兜底: %s, %s", first[0].ID, first[1].ID)
	}
}

// TestQueryItemsRandomSort 随机播放依赖服务端真随机（ORDER BY RANDOM()）：
// 每次请求重新抽样，偏移没有意义，且默认只返回一页样本。
func TestQueryItemsRandomSort(t *testing.T) {
	st := openTestStore(t)
	seedItems(t, st)
	ctx := context.Background()

	if got := buildOrderBy([]string{"Random"}, "Descending"); got != "RANDOM(), i.id ASC" {
		t.Fatalf("Random 排序拼接结果 = %q", got)
	}

	// 偏移被忽略：即使传越界的 StartIndex，也要返回随机样本而不是空列表。
	list, total, err := st.QueryItems(ctx, ItemQuery{
		UserID: "u1", SortBy: []string{"Random"}, StartIndex: 99, Limit: 2,
	})
	if err != nil || total != 3 || len(list) != 2 {
		t.Fatalf("随机抽样 list=%d total=%d err=%v", len(list), total, err)
	}

	// 未显式给 Limit 时随机模式默认只取 RandomSampleSize 条。
	for index := 0; index < 60; index++ {
		name := fmt.Sprintf("Random%02d", index)
		if err := st.UpsertItem(ctx, &Item{
			ID: name, LibraryID: "lib1", ParentID: "lib1", Type: "Movie",
			Name: name, SortName: name,
		}); err != nil {
			t.Fatalf("写入条目 %s 失败: %v", name, err)
		}
	}
	list, total, err = st.QueryItems(ctx, ItemQuery{UserID: "u1", SortBy: []string{"Random"}})
	if err != nil || total != 63 || len(list) != RandomSampleSize {
		t.Fatalf("随机默认取样 list=%d total=%d err=%v", len(list), total, err)
	}
	// 抽样结果不能重复（SQL 层面就是一次洗牌后的前 N 条）。
	seen := make(map[string]bool, len(list))
	for _, item := range list {
		if seen[item.ID] {
			t.Fatalf("随机结果出现重复条目 %s", item.ID)
		}
		seen[item.ID] = true
	}
}
