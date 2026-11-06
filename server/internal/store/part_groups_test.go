package store

import (
	"context"
	"path/filepath"
	"testing"
)

// partItem 构造一条带分片归属的电影条目，分辨率一致以满足结构校验。
func partItem(id, groupKey string, index int) *Item {
	return &Item{
		ID:           id,
		LibraryID:    "lib1",
		ParentID:     "lib1",
		Type:         "Movie",
		Name:         "3070118",
		SortName:     "3070118",
		Width:        1920,
		Height:       1080,
		PartGroupKey: groupKey,
		PartIndex:    index,
	}
}

// TestSiblingItemsOrderedByPartIndex 验证兄弟列表按序号数字排序，并带上当前项标记。
func TestSiblingItemsOrderedByPartIndex(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	const key = "lib1||3070118"
	for _, item := range []*Item{
		partItem("p10", key, 10),
		partItem("p2", key, 2),
		partItem("p1", key, 1),
	} {
		if err := st.UpsertItem(ctx, item); err != nil {
			t.Fatalf("写入条目失败: %v", err)
		}
	}

	siblings, err := st.SiblingItems(ctx, "u1", "p2")
	if err != nil {
		t.Fatalf("查询分片列表失败: %v", err)
	}
	want := []string{"p1", "p2", "p10"}
	if len(siblings) != len(want) {
		t.Fatalf("分片数量=%d，期望 %d", len(siblings), len(want))
	}
	for index, id := range want {
		if siblings[index].ID != id {
			t.Fatalf("第 %d 项为 %s，期望 %s（不能按字符串排序）", index, siblings[index].ID, id)
		}
	}
	if !siblings[1].IsCurrent {
		t.Fatal("当前条目应带 IsCurrent 标记")
	}
	if siblings[0].PartCount == nil || *siblings[0].PartCount != 3 {
		t.Fatalf("分片总数不符: %+v", siblings[0].PartCount)
	}

	// 详情接口同样带上分片标量，前端不必等兄弟接口。
	detail, err := st.GetItem(ctx, "u1", "p1")
	if err != nil {
		t.Fatal(err)
	}
	if detail.PartIndex == nil || *detail.PartIndex != 1 ||
		detail.PartCount == nil || *detail.PartCount != 3 {
		t.Fatalf("详情未补齐分片信息: %+v", detail)
	}
}

// TestDeleteItemsCleansItemGroups 验证条目删除后归属行跟着删除，
// 并把它兄弟的分片数刷回实际成员数（区块能不能自动消失取决于这一步）。
func TestDeleteItemsCleansItemGroups(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	const key = "lib1||3070118"
	for _, item := range []*Item{partItem("p1", key, 1), partItem("p2", key, 2)} {
		if err := st.UpsertItem(ctx, item); err != nil {
			t.Fatal(err)
		}
	}

	if err := st.DeleteItems(ctx, []string{"p2"}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ItemGroupOf(ctx, "p2"); err != ErrNotFound {
		t.Fatalf("删除后归属行应被清理，得到 %v", err)
	}
	group, err := st.ItemGroupOf(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if group.PartCount != 1 {
		t.Fatalf("剩余分片数=%d，期望 1", group.PartCount)
	}
}

// TestBackfillItemGroups 验证老库升级后不重新扫描也能补齐分片归属。
func TestBackfillItemGroups(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	root := t.TempDir()
	if err := st.SaveLibrary(ctx, Library{
		ID: "lib1", Name: "影片", CollectionType: "movies", Paths: []string{root},
	}); err != nil {
		t.Fatalf("保存媒体库失败: %v", err)
	}

	// 直接写条目、不设 PartGroupKey：模拟升级前入库、还没有归属行的老数据。
	for index, name := range []string{"3070118_1.mp4", "3070118_2.mp4"} {
		if err := st.UpsertItem(ctx, &Item{
			ID:        name,
			LibraryID: "lib1",
			ParentID:  "lib1",
			Type:      "Movie",
			Name:      name,
			SortName:  name,
			Path:      filepath.Join(root, name),
			Width:     1920,
			Height:    1080,
			Container: "mp4",
		}); err != nil {
			t.Fatalf("写入条目 %d 失败: %v", index, err)
		}
	}

	if err := st.BackfillItemGroups(ctx); err != nil {
		t.Fatalf("回填失败: %v", err)
	}

	siblings, err := st.SiblingItems(ctx, "u1", "3070118_1.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if len(siblings) != 2 {
		t.Fatalf("回填后应有 2 个分片，实际 %d", len(siblings))
	}
	if siblings[1].ID != "3070118_2.mp4" {
		t.Fatalf("分片顺序不符: %+v", siblings)
	}
}

// TestGroupStructureMismatchSkipsGrouping 验证分辨率不一致时放弃分组，
// 但条目本身仍能正常入库（归属是旁路能力，不能阻断入库）。
func TestGroupStructureMismatchSkipsGrouping(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	const key = "lib1||mismatch"
	if err := st.UpsertItem(ctx, partItem("p1", key, 1)); err != nil {
		t.Fatal(err)
	}
	other := partItem("p2", key, 2)
	other.Width, other.Height = 1280, 720
	if err := st.UpsertItem(ctx, other); err != nil {
		t.Fatalf("结构不一致不应阻断入库: %v", err)
	}

	if _, err := st.ItemGroupOf(ctx, "p2"); err != ErrNotFound {
		t.Fatalf("结构不一致的分片不应成组，得到 %v", err)
	}
	// 已入库的那一条不受影响。
	if group, err := st.ItemGroupOf(ctx, "p1"); err != nil || group.PartCount != 1 {
		t.Fatalf("原有分片归属被破坏: %+v err=%v", group, err)
	}
}
