package media

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// staticOwners 返回固定的缓存归属，避免为了测回收去开数据库。
func staticOwners(owners map[string]string) func(context.Context) (map[string]string, error) {
	return func(context.Context) (map[string]string, error) { return owners, nil }
}

// writeCacheFile 造一个占位缓存文件，内容长度决定目录体积。
func writeCacheFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("创建目录失败: %v", err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatalf("写入文件失败: %v", err)
	}
}

func TestCacheJanitorRemovesOrphans(t *testing.T) {
	imageDir, bifDir := t.TempDir(), t.TempDir()

	writeCacheFile(t, filepath.Join(imageDir, "own1", "primary-0-tag-w720-q82.jpg"), 64)
	writeCacheFile(t, filepath.Join(imageDir, "person1", "primary-0-tag-w260-q82.jpg"), 64)
	writeCacheFile(t, filepath.Join(imageDir, "orphan", "primary-0-tag-w720-q82.jpg"), 64)

	// 人物头像同样落在 cache/images/{personID}，不能当孤儿删。
	owners := map[string]string{"own1": "", "person1": ""}
	janitor := NewCacheJanitor(imageDir, bifDir, 0, 0, staticOwners(owners), nil)

	ownBif := filepath.Join(bifDir, "own1-w320-i10000.bif")
	orphanBif := filepath.Join(bifDir, "orphan-w320-i10000.bif")
	writeCacheFile(t, ownBif, 64)
	writeCacheFile(t, orphanBif, 64)

	result, err := janitor.Sweep(context.Background())
	if err != nil {
		t.Fatalf("回收失败: %v", err)
	}
	if result.RemovedDirs != 1 || result.RemovedFiles != 1 {
		t.Fatalf("删除统计 = %+v，期望各删 1 个", result)
	}
	if _, err := os.Stat(filepath.Join(imageDir, "orphan")); !os.IsNotExist(err) {
		t.Errorf("孤儿图片目录应被删除")
	}
	if _, err := os.Stat(orphanBif); !os.IsNotExist(err) {
		t.Errorf("孤儿 BIF 应被删除")
	}
	for _, path := range []string{
		filepath.Join(imageDir, "own1"),
		filepath.Join(imageDir, "person1"),
		ownBif,
	} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("有效缓存 %s 被误删: %v", filepath.Base(path), err)
		}
	}
}

func TestCacheJanitorEvictsLeastRecentlyUsed(t *testing.T) {
	imageDir, bifDir := t.TempDir(), t.TempDir()
	renderer := NewImageRenderer(imageDir)
	raw := makePNG(t, 40, 20, false)

	// 走一次渲染，既建出缓存目录，也刷新访问时间。
	for _, id := range []string{"own1", "own2"} {
		if _, _, err := renderer.Render(id, "Primary", 0, raw, 20, 82); err != nil {
			t.Fatalf("渲染 %s 失败: %v", id, err)
		}
	}
	// 直接把访问时间改成「一小时前」，避免用 sleep 制造顺序差异。
	renderer.access["own1"] = time.Now().Add(-time.Hour)

	owners := map[string]string{"own1": "", "own2": ""}
	// 上限只放得下一个目录，逼出淘汰逻辑。
	limit := dirSize(filepath.Join(imageDir, "own2"))
	janitor := NewCacheJanitor(imageDir, bifDir, limit, 0, staticOwners(owners), renderer)

	if _, err := janitor.Sweep(context.Background()); err != nil {
		t.Fatalf("回收失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(imageDir, "own1")); !os.IsNotExist(err) {
		t.Errorf("最久未访问的目录应被淘汰")
	}
	if _, err := os.Stat(filepath.Join(imageDir, "own2")); err != nil {
		t.Errorf("最近访问的目录不应被淘汰: %v", err)
	}
}

func TestCacheJanitorRemovesStaleBif(t *testing.T) {
	imageDir, bifDir := t.TempDir(), t.TempDir()

	source := filepath.Join(t.TempDir(), "movie.mp4")
	if err := os.WriteFile(source, []byte("video"), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Hour)
	if err := os.Chtimes(source, future, future); err != nil {
		t.Fatal(err)
	}

	staleBif := filepath.Join(bifDir, "own1-w320-i10000.bif")
	writeCacheFile(t, staleBif, 64)

	janitor := NewCacheJanitor(imageDir, bifDir, 0, 0, staticOwners(map[string]string{"own1": source}), nil)
	if _, err := janitor.Sweep(context.Background()); err != nil {
		t.Fatalf("回收失败: %v", err)
	}
	if _, err := os.Stat(staleBif); !os.IsNotExist(err) {
		t.Errorf("片源已更新的 BIF 缓存应被删除")
	}
}

func TestCacheJanitorRemoveItem(t *testing.T) {
	imageDir, bifDir := t.TempDir(), t.TempDir()
	renderer := NewImageRenderer(imageDir)

	// 条目删除时两层缓存都要立刻清掉，不必等定时任务。
	writeCacheFile(t, filepath.Join(imageDir, "item1", "primary-0-tag-w720-q82.jpg"), 64)
	drop := []string{
		filepath.Join(bifDir, "item1-w320-i10000.bif"),
		filepath.Join(bifDir, "item1.bif"),
	}
	keep := filepath.Join(bifDir, "item10-w320-i10000.bif")
	for _, path := range append(append([]string{}, drop...), keep) {
		writeCacheFile(t, path, 64)
	}

	janitor := NewCacheJanitor(imageDir, bifDir, 0, 0, staticOwners(nil), renderer)
	janitor.RemoveItem("item1")

	if _, err := os.Stat(filepath.Join(imageDir, "item1")); !os.IsNotExist(err) {
		t.Errorf("条目图片缓存应被删除")
	}
	for _, path := range drop {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("BIF %s 应被删除", filepath.Base(path))
		}
	}
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("前缀相同的其它条目被误删: %v", err)
	}
}
