package media

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestPackBIFRoundTrip 校验打包出来的索引能和帧数据对上：
// 客户端就是按「时间戳 → 偏移」这张表取图的，表错一位预览就全错。
func TestPackBIFRoundTrip(t *testing.T) {
	frames := [][]byte{
		{0xff, 0xd8, 1},
		{0xff, 0xd8, 2, 2},
		{0xff, 0xd8, 3, 3, 3},
	}
	const intervalMs = 10000

	packed := PackBIF(frames, intervalMs)
	if packed[0] != 0x89 || string(packed[1:4]) != "BIF" {
		t.Fatalf("BIF 头部标识错误: % x", packed[:4])
	}
	if got := binary.LittleEndian.Uint32(packed[4:8]); got != 1 {
		t.Fatalf("版本号 = %d，期望 1", got)
	}
	if got := binary.LittleEndian.Uint32(packed[8:12]); got != uint32(len(frames)) {
		t.Fatalf("帧数 = %d，期望 %d", got, len(frames))
	}
	if got := binary.LittleEndian.Uint32(packed[12:16]); got != intervalMs {
		t.Fatalf("抽帧间隔 = %d，期望 %d", got, intervalMs)
	}

	const headerLength, indexEntryLength = 64, 8
	for index := range frames {
		entry := headerLength + index*indexEntryLength
		timestamp := binary.LittleEndian.Uint32(packed[entry : entry+4])
		if timestamp != uint32(index)*intervalMs {
			t.Errorf("第 %d 项时间戳 = %d", index, timestamp)
		}
		start := int(binary.LittleEndian.Uint32(packed[entry+4 : entry+8]))
		end := int(binary.LittleEndian.Uint32(packed[entry+4+indexEntryLength : entry+8+indexEntryLength]))
		if !bytes.Equal(packed[start:end], frames[index]) {
			t.Errorf("第 %d 帧数据与原始帧不一致", index)
		}
	}

	// 哨兵项：时间戳无效，偏移指向数据区末尾。
	sentinel := headerLength + len(frames)*indexEntryLength
	if got := binary.LittleEndian.Uint32(packed[sentinel : sentinel+4]); got != 0xFFFFFFFF {
		t.Fatalf("哨兵时间戳 = %#x，期望 0xFFFFFFFF", got)
	}
	if got := int(binary.LittleEndian.Uint32(packed[sentinel+4 : sentinel+8])); got != len(packed) {
		t.Fatalf("哨兵偏移 = %d，期望 %d", got, len(packed))
	}
}

// writeBif 直接落一个可用的 BIF 缓存文件（不跑 ffmpeg）。
func writeBif(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("创建缓存目录失败: %v", err)
	}
	data := PackBIF([][]byte{[]byte("frame")}, 10000)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("写入 BIF 失败: %v", err)
	}
}

func TestBifCacheLookupAndVariantReuse(t *testing.T) {
	dir := t.TempDir()
	cache := NewBifCache(dir, "ffmpeg")

	// 注意参数顺序：Lookup(itemID, sourcePath, intervalMs, width)，与 Path 的 (width, intervalMs) 相反。
	target := cache.Path("item1", 320, 10000)
	writeBif(t, target)

	if hit := cache.Lookup("item1", "", 10000, 320); hit != target {
		t.Fatalf("参数一致的缓存未命中: %q", hit)
	}
	// 播放侧允许复用其它宽度：换宽度不该再解一遍整部片。
	if hit := cache.Lookup("item1", "", 10000, 640); hit != target {
		t.Fatalf("跨参数复用失败: %q", hit)
	}
	// 前缀相同的其它条目不能被当成复用目标。
	if hit := cache.Lookup("item10", "", 10000, 320); hit != "" {
		t.Fatalf("误命中前缀相同的条目: %q", hit)
	}
}

func TestBifCacheRejectsStaleSource(t *testing.T) {
	dir := t.TempDir()
	cache := NewBifCache(dir, "ffmpeg")

	cachePath := cache.Path("item1", 320, 10000)
	writeBif(t, cachePath)

	source := filepath.Join(t.TempDir(), "movie.mp4")
	if err := os.WriteFile(source, []byte("video"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 片源比缓存新：说明视频被替换过，旧缩略图不能再用。
	future := time.Now().Add(time.Hour)
	if err := os.Chtimes(source, future, future); err != nil {
		t.Fatal(err)
	}
	if hit := cache.Lookup("item1", source, 10000, 320); hit != "" {
		t.Fatalf("陈旧缓存不应命中: %q", hit)
	}

	// 缓存比片源新则正常命中。
	if err := os.Chtimes(cachePath, future.Add(time.Hour), future.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if hit := cache.Lookup("item1", source, 10000, 320); hit != cachePath {
		t.Fatalf("缓存应命中: %q", hit)
	}
}

func TestBifCacheLegacyRename(t *testing.T) {
	dir := t.TempDir()
	cache := NewBifCache(dir, "ffmpeg")

	legacy := cache.legacyPath("item1")
	writeBif(t, legacy)

	hit := cache.Lookup("item1", "", 10000, 320)
	if hit != cache.Path("item1", 320, 10000) {
		t.Fatalf("早期无参数文件应被改名复用，得到 %q", hit)
	}
	if _, err := os.Stat(legacy); !os.IsNotExist(err) {
		t.Fatalf("改名后旧文件应不存在: %v", err)
	}
}

func TestBifCacheRemoveItem(t *testing.T) {
	dir := t.TempDir()
	cache := NewBifCache(dir, "ffmpeg")

	keep := []string{
		cache.Path("item10", 320, 10000),
		cache.Path("item2", 320, 10000),
	}
	drop := []string{
		cache.Path("item1", 320, 10000),
		cache.Path("item1", 640, 10000),
		cache.legacyPath("item1"),
	}
	for _, path := range append(append([]string{}, keep...), drop...) {
		writeBif(t, path)
	}

	cache.RemoveItem("item1")
	for _, path := range drop {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("缓存 %s 应被删除", filepath.Base(path))
		}
	}
	// 前缀相同（item10）与其它条目必须保留。
	for _, path := range keep {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("缓存 %s 被误删: %v", filepath.Base(path), err)
		}
	}
}
