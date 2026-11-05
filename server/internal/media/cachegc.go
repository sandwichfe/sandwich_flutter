package media

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// CacheJanitor 回收 data/cache 下的两类垃圾（S4.1）：
//
//   - 孤儿：条目/人物已被删除，缓存目录或 BIF 文件还留着；
//   - 超量：宽度/画质/抽帧间隔换过之后，旧参数的文件永远不会再命中。
//
// 回收是尽力而为的后台任务：单个文件删除失败只跳过，不影响服务运行。
type CacheJanitor struct {
	imageDir string
	bifDir   string
	// imageLimit / bifLimit 是字节数，<= 0 表示只清孤儿、不按容量淘汰。
	imageLimit int64
	bifLimit   int64
	// owners 返回仍有效的缓存归属（条目 ID → 源文件路径，人物 ID → 空串）。
	owners func(context.Context) (map[string]string, error)
	// renderer 提供条目最近一次渲染时间，让容量淘汰接近 LRU；可为 nil。
	renderer *ImageRenderer
}

func NewCacheJanitor(imageDir, bifDir string, imageLimit, bifLimit int64,
	owners func(context.Context) (map[string]string, error), renderer *ImageRenderer) *CacheJanitor {
	return &CacheJanitor{
		imageDir:   imageDir,
		bifDir:     bifDir,
		imageLimit: imageLimit,
		bifLimit:   bifLimit,
		owners:     owners,
		renderer:   renderer,
	}
}

// CacheSweepResult 是一轮回收的统计，只用于日志。
type CacheSweepResult struct {
	RemovedDirs  int
	RemovedFiles int
	FreedBytes   int64
}

// Run 阻塞执行定时回收，ctx 取消后返回。
//
// 启动后先跑一轮：上次进程退出前删除的条目会留下孤儿缓存，
// 不必等第一个 tick。
func (j *CacheJanitor) Run(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		return
	}
	j.sweepAndLog(ctx)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			j.sweepAndLog(ctx)
		}
	}
}

func (j *CacheJanitor) sweepAndLog(ctx context.Context) {
	result, err := j.Sweep(ctx)
	if err != nil {
		// 关停期间数据库已关闭，这类错误不用报。
		if ctx.Err() == nil {
			log.Printf("缓存回收失败: %v", err)
		}
		return
	}
	if result.RemovedDirs > 0 || result.RemovedFiles > 0 {
		log.Printf("缓存回收完成: 删除目录 %d 个、文件 %d 个，释放 %.1f MB",
			result.RemovedDirs, result.RemovedFiles, float64(result.FreedBytes)/(1<<20))
	}
}

// RemoveItem 立即清理某个条目的两层缓存，条目删除时由扫描器调用。
func (j *CacheJanitor) RemoveItem(itemID string) {
	if j.renderer != nil {
		j.renderer.RemoveItem(itemID)
	} else {
		_ = os.RemoveAll(filepath.Join(j.imageDir, sanitizeID(itemID)))
	}
	removeBifVariants(j.bifDir, sanitizeID(itemID))
}

// Sweep 执行一轮回收。
func (j *CacheJanitor) Sweep(ctx context.Context) (CacheSweepResult, error) {
	var result CacheSweepResult
	owners, err := j.owners(ctx)
	if err != nil {
		return result, err
	}
	j.sweepImages(ctx, owners, &result)
	j.sweepBif(ctx, owners, &result)
	return result, nil
}

// cacheDirEntry 是图片缓存目录（一个条目/人物一个目录）的汇总信息。
type cacheDirEntry struct {
	path     string
	size     int64
	accessed time.Time
}

func (j *CacheJanitor) sweepImages(ctx context.Context, owners map[string]string, result *CacheSweepResult) {
	entries, err := os.ReadDir(j.imageDir)
	if err != nil {
		return
	}

	alive := make([]cacheDirEntry, 0, len(entries))
	for _, entry := range entries {
		if ctx.Err() != nil {
			return
		}
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		path := filepath.Join(j.imageDir, id)
		size := dirSize(path)

		if _, ok := owners[id]; !ok {
			if os.RemoveAll(path) == nil {
				result.RemovedDirs++
				result.FreedBytes += size
			}
			continue
		}

		// 优先用渲染时的访问时间；进程刚启动还没访问过就退回目录 mtime。
		accessed := time.Time{}
		if j.renderer != nil {
			accessed = j.renderer.LastAccess(id)
		}
		if accessed.IsZero() {
			if info, err := entry.Info(); err == nil {
				accessed = info.ModTime()
			}
		}
		alive = append(alive, cacheDirEntry{path: path, size: size, accessed: accessed})
	}

	if j.imageLimit <= 0 {
		return
	}
	total := int64(0)
	for _, entry := range alive {
		total += entry.size
	}
	if total <= j.imageLimit {
		return
	}
	// 按目录整体淘汰：一个条目往往同时有多张图，留半套没有意义。
	sort.Slice(alive, func(a, b int) bool {
		return alive[a].accessed.Before(alive[b].accessed)
	})
	for _, entry := range alive {
		if total <= j.imageLimit {
			return
		}
		if os.RemoveAll(entry.path) == nil {
			total -= entry.size
			result.RemovedDirs++
			result.FreedBytes += entry.size
		}
	}
}

// bifEntry 是单个 BIF 缓存文件的汇总信息。
type bifEntry struct {
	path string
	size int64
	mod  time.Time
}

func (j *CacheJanitor) sweepBif(ctx context.Context, owners map[string]string, result *CacheSweepResult) {
	entries, err := os.ReadDir(j.bifDir)
	if err != nil {
		return
	}

	alive := make([]bifEntry, 0, len(entries))
	for _, entry := range entries {
		if ctx.Err() != nil {
			return
		}
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		path := filepath.Join(j.bifDir, entry.Name())
		itemID := bifOwnerID(entry.Name())

		sourcePath, owned := owners[itemID]
		stale := !owned
		if !stale && sourcePath != "" {
			// 片源被替换过（变新）的缩略图永远不会再命中，直接删。
			if src, statErr := os.Stat(sourcePath); statErr == nil && src.ModTime().After(info.ModTime()) {
				stale = true
			}
		}
		if stale {
			if os.Remove(path) == nil {
				result.RemovedFiles++
				result.FreedBytes += info.Size()
			}
			continue
		}
		alive = append(alive, bifEntry{path: path, size: info.Size(), mod: info.ModTime()})
	}

	if j.bifLimit <= 0 {
		return
	}
	total := int64(0)
	for _, entry := range alive {
		total += entry.size
	}
	if total <= j.bifLimit {
		return
	}
	// BIF 是整部片一次抽帧的产物，重复生成代价高，按旧到新淘汰。
	sort.Slice(alive, func(a, b int) bool { return alive[a].mod.Before(alive[b].mod) })
	for _, entry := range alive {
		if total <= j.bifLimit {
			return
		}
		if os.Remove(entry.path) == nil {
			total -= entry.size
			result.RemovedFiles++
			result.FreedBytes += entry.size
		}
	}
}

// bifOwnerID 从缓存文件名反推归属 ID。
// 命名只有 "<id>.bif"（早期）与 "<id>-w<宽>-i<间隔>.bif" 两种，ID 是十六进制、不含连字符。
func bifOwnerID(name string) string {
	name = strings.TrimSuffix(name, filepath.Ext(name))
	if index := strings.Index(name, "-"); index > 0 {
		name = name[:index]
	}
	return name
}

// removeBifVariants 按前缀删除某个条目的全部 BIF 变体。
func removeBifVariants(dir, prefix string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if name != prefix+".bif" && !strings.HasPrefix(name, prefix+"-") {
			continue
		}
		_ = os.Remove(filepath.Join(dir, name))
	}
}

// dirSize 统计目录内所有文件大小，读不到的项按 0 计。
func dirSize(dir string) int64 {
	var total int64
	_ = filepath.WalkDir(dir, func(_ string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		if info, err := entry.Info(); err == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}
