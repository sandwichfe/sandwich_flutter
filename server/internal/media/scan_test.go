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
		Fingerprint: fileFingerprint(info),
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
