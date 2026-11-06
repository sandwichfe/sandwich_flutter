package media

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"embyx/internal/store"
)

func TestDeriveItemIDPrefersProviderIDs(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "Avatar.mkv")

	withTmdb := deriveItemID(&NFOData{UniqueIDs: map[string]string{"tmdb": "19995", "imdb": "tt0499549"}}, "lib1", dir, video)
	if want := store.StableID("tmdb:19995"); withTmdb != want {
		t.Errorf("应当优先用 TMDB 编号: got %q want %q", withTmdb, want)
	}

	onlyImdb := deriveItemID(&NFOData{UniqueIDs: map[string]string{"imdb": "tt0499549"}}, "lib1", dir, video)
	if want := store.StableID("imdb:tt0499549"); onlyImdb != want {
		t.Errorf("没有 TMDB 时应回退 IMDb: got %q want %q", onlyImdb, want)
	}

	// 没有外部编号时退回「库 ID + 相对路径」。
	byPath := deriveItemID(nil, "lib1", dir, video)
	if byPath == withTmdb || byPath == "" {
		t.Errorf("无外部编号时应按路径派生, 实际 %q", byPath)
	}
}

func TestDeriveItemIDIgnoresRootAndCase(t *testing.T) {
	// 同一个库换盘符 / 挂载点后，相对路径不变，ID 必须保持不变。
	first := deriveItemID(nil, "lib1", filepath.FromSlash("D:/media"), filepath.FromSlash("D:/media/Action/Avatar.mkv"))
	second := deriveItemID(nil, "lib1", filepath.FromSlash("E:/media"), filepath.FromSlash("E:/media/action/avatar.MKV"))
	if first != second {
		t.Errorf("换盘或大小写变化不应改变 ID: %q vs %q", first, second)
	}
}

func TestBuildItemSkipsProbeWhenFingerprintMatches(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "movie.mp4")
	if err := os.WriteFile(video, []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	info, err := os.Stat(video)
	if err != nil {
		t.Fatal(err)
	}
	itemID := deriveItemID(nil, "lib1", dir, video)
	if err := st.UpsertItem(context.Background(), &store.Item{
		ID:          itemID,
		LibraryID:   "lib1",
		ParentID:    "lib1",
		Type:        "Movie",
		Name:        "movie",
		SortName:    "movie",
		Path:        video,
		Fingerprint: artworkFingerprint(info, nil),
	}); err != nil {
		t.Fatalf("写入条目失败: %v", err)
	}

	// prober 指向不存在的可执行文件：一旦真的去探测就会报错，
	// 能正常返回就说明指纹命中、完全跳过了 ffprobe。
	scanner := &Scanner{store: st, prober: NewProber(filepath.Join(dir, "missing-ffprobe"))}
	item, needWrite, err := scanner.buildItem(context.Background(), "lib1", dir, video, func(string, ...any) {})
	if err != nil {
		t.Fatalf("指纹命中时不应报错: %v", err)
	}
	if needWrite || item != nil {
		t.Errorf("指纹命中应跳过写库, 实际 needWrite=%v item=%v", needWrite, item)
	}
}

func TestBuildItemProbesWhenFingerprintChanges(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "movie.mp4")
	if err := os.WriteFile(video, []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	itemID := deriveItemID(nil, "lib1", dir, video)
	if err := st.UpsertItem(context.Background(), &store.Item{
		ID:          itemID,
		LibraryID:   "lib1",
		ParentID:    "lib1",
		Type:        "Movie",
		Name:        "movie",
		SortName:    "movie",
		Path:        video,
		Fingerprint: "0:0", // 与真实文件不一致，必须走完整探测
	}); err != nil {
		t.Fatalf("写入条目失败: %v", err)
	}

	// 指纹不一致时必须重新探测：prober 指向不存在的可执行文件，因此应当返回错误。
	scanner := &Scanner{store: st, prober: NewProber(filepath.Join(dir, "missing-ffprobe"))}
	if _, _, err := scanner.buildItem(context.Background(), "lib1", dir, video, func(string, ...any) {}); err == nil {
		t.Error("指纹不一致时应重新探测，实际却直接返回成功")
	}
}

func TestBuildItemProbesWhenExtraFanartAdded(t *testing.T) {
	// 片源没动、只往 extrafanart 里补图时，也必须重新导入一次，否则新图永远扫不到。
	dir := t.TempDir()
	video := filepath.Join(dir, "movie.mp4")
	if err := os.WriteFile(video, []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	info, err := os.Stat(video)
	if err != nil {
		t.Fatal(err)
	}
	itemID := deriveItemID(nil, "lib1", dir, video)
	if err := st.UpsertItem(context.Background(), &store.Item{
		ID:          itemID,
		LibraryID:   "lib1",
		ParentID:    "lib1",
		Type:        "Movie",
		Name:        "movie",
		SortName:    "movie",
		Path:        video,
		Fingerprint: artworkFingerprint(info, nil),
	}); err != nil {
		t.Fatalf("写入条目失败: %v", err)
	}

	if err := os.MkdirAll(filepath.Join(dir, "extrafanart"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "extrafanart", "fanart1.jpg"), []byte("img"), 0o644); err != nil {
		t.Fatal(err)
	}

	scanner := &Scanner{store: st, prober: NewProber(filepath.Join(dir, "missing-ffprobe"))}
	if _, _, err := scanner.buildItem(context.Background(), "lib1", dir, video, func(string, ...any) {}); err == nil {
		t.Error("extrafanart 变化后应重新探测并导入图片，实际却直接返回成功")
	}
}

func TestExtraFanartPrefersVideoNamedDir(t *testing.T) {
	dir := t.TempDir()
	// 同目录多部片时，<视频名>-extrafanart 只属于对应条目；共用的 extrafanart 兜底。
	for _, name := range []string{"extrafanart", "Movie-extrafanart"} {
		if err := os.MkdirAll(filepath.Join(dir, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "extrafanart", "fanart1.jpg"), []byte("shared"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Movie-extrafanart", "own.jpg"), []byte("own"), 0o644); err != nil {
		t.Fatal(err)
	}

	snapshot := &dirSnapshot{extraFanart: readExtraFanartIndex(dir)}
	if got := snapshot.extraFanartFor("Movie.mkv"); len(got) != 1 || filepath.Base(got[0]) != "own.jpg" {
		t.Errorf("应优先使用 <视频名>-extrafanart, 实际 %v", got)
	}
	if got := snapshot.extraFanartFor("Other.mkv"); len(got) != 1 || filepath.Base(got[0]) != "fanart1.jpg" {
		t.Errorf("没有同名目录时应回退到共用 extrafanart, 实际 %v", got)
	}
}

func TestReadExtraFanartImagesSortsNaturally(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "extrafanart")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// 字典序会把 fanart10 排在 fanart2 前面，这里要求按数字大小排。
	names := []string{"fanart10.jpg", "fanart2.jpg", "fanart1.png", "note.txt"}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	got := readExtraFanartImages(dir)
	want := []string{"fanart1.png", "fanart2.jpg", "fanart10.jpg"}
	if len(got) != len(want) {
		t.Fatalf("期望 %v, 实际 %v", want, got)
	}
	for index := range want {
		if filepath.Base(got[index]) != want[index] {
			t.Fatalf("期望 %v, 实际 %v", want, got)
		}
	}
}

func TestImportArtworkCachesExtraFanart(t *testing.T) {
	dir := t.TempDir()
	video := filepath.Join(dir, "Movie.mkv")
	mustWriteFile(t, video, "video")
	mustWriteFile(t, filepath.Join(dir, "fanart.jpg"), "main-fanart")
	if err := os.MkdirAll(filepath.Join(dir, "extrafanart"), 0o755); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, filepath.Join(dir, "extrafanart", "fanart1.jpg"), "extra-1")
	mustWriteFile(t, filepath.Join(dir, "extrafanart", "fanart2.jpg"), "extra-2")

	st, err := store.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	images := NewImageStore(filepath.Join(dir, "images"))
	scanner := &Scanner{store: st, images: images}
	item := &store.Item{
		ID:           "item1",
		LibraryID:    "lib1",
		ImageTags:    map[string]string{},
		BackdropTags: []string{},
	}
	scanner.importArtwork(item, video, func(string, ...any) {})

	// fanart.jpg 仍是 0 号（详情页顶部大图），extrafanart 依次追加在后面。
	if len(item.BackdropTags) != 3 {
		t.Fatalf("应导入 1 张背景 + 2 张艺术图, 实际 %d 张", len(item.BackdropTags))
	}
	for index, want := range []string{"main-fanart", "extra-1", "extra-2"} {
		raw, err := images.LoadItemImage("item1", "Backdrop", index)
		if err != nil {
			t.Fatalf("第 %d 张应已落盘: %v", index, err)
		}
		if string(raw) != want {
			t.Errorf("第 %d 张内容应为 %q, 实际 %q", index, want, string(raw))
		}
	}

	// 源端删掉一张艺术图后重新扫描：多出来的槽位要被回收，标签也只保留现有的。
	if err := os.Remove(filepath.Join(dir, "extrafanart", "fanart2.jpg")); err != nil {
		t.Fatal(err)
	}
	scanner.dirCache = nil
	item2 := &store.Item{
		ID:           "item1",
		LibraryID:    "lib1",
		ImageTags:    map[string]string{},
		BackdropTags: []string{},
	}
	scanner.importArtwork(item2, video, func(string, ...any) {})
	if len(item2.BackdropTags) != 2 {
		t.Fatalf("删图后应只剩 2 张, 实际 %d 张", len(item2.BackdropTags))
	}
	if images.HasItemImage("item1", "Backdrop", 2) {
		t.Error("多余的第 3 个槽位应被清理")
	}
}

func mustWriteFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("写入 %s 失败: %v", path, err)
	}
}
