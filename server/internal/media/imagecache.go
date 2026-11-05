package media

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

// maxRenderWidth 是缩放宽度的上限：客户端传什么都不能让服务端去解一张超大图。
const maxRenderWidth = 2000

// defaultImageQuality 与 Render 的默认画质保持一致。
const defaultImageQuality = 82

// ImageRenderer 负责图片缩放、并发限流与磁盘缓存。
//
// 缓存文件名里带源图的内容标签：源图被替换后标签变化，旧文件自然不再命中，
// 因此不需要在换图时主动失效缓存（旧文件由缓存回收任务处理）。
type ImageRenderer struct {
	dir string
	// sem 限制同时进行的解码/缩放数量，避免一屏图片把 CPU 打满影响播放。
	sem chan struct{}
	// group 合并同一张图的并发请求：列表重建时同一 URL 常被连发两次。
	group flightGroup
}

func NewImageRenderer(dir string) *ImageRenderer {
	return &ImageRenderer{
		dir: dir,
		sem: make(chan struct{}, runtime.NumCPU()),
	}
}

// Render 返回按 maxWidth / quality 缩放后的 JPEG，并返回源图内容标签（供 ETag 使用）。
func (p *ImageRenderer) Render(itemID, imageType string, index int, raw []byte, maxWidth, quality int) ([]byte, string, error) {
	tag := hashTag(raw)
	maxWidth = NormalizeRenderWidth(maxWidth)
	quality = NormalizeRenderQuality(quality)
	path := p.cachePath(itemID, imageType, index, tag, maxWidth, quality)

	if cached, ok := readCachedImage(path); ok {
		return cached, tag, nil
	}

	data, err := p.group.Do(path, func() ([]byte, error) {
		// 等锁期间同批请求可能已经写好缓存。
		if cached, ok := readCachedImage(path); ok {
			return cached, nil
		}

		p.sem <- struct{}{}
		defer func() { <-p.sem }()

		rendered, err := Render(raw, maxWidth, quality)
		if err != nil {
			return nil, err
		}
		if len(rendered) > 0 {
			// 缓存写失败不影响本次返回，下次再算一遍即可。
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err == nil {
				_ = writeFileAtomic(path, rendered)
			}
		}
		return rendered, nil
	})
	return data, tag, err
}

// RemoveItem 删除条目全部缩放缓存。条目被删除或图片被替换时调用，回收磁盘。
func (p *ImageRenderer) RemoveItem(itemID string) {
	_ = os.RemoveAll(filepath.Join(p.dir, sanitizeID(itemID)))
}

// cachePath 按「条目/类型-序号-源图标签-宽度-画质」组织缓存文件。
func (p *ImageRenderer) cachePath(itemID, imageType string, index int, tag string, width, quality int) string {
	name := fmt.Sprintf("%s-%d-%s-w%d-q%d.jpg",
		strings.ToLower(sanitizeID(imageType)), index, tag, width, quality)
	return filepath.Join(p.dir, sanitizeID(itemID), name)
}

// NormalizeRenderWidth 把请求宽度钳到有效范围，0 表示保持原宽。
// 导出是为了让 HTTP 层的 ETag 和缓存 key 使用同一份参数。
func NormalizeRenderWidth(width int) int {
	if width < 0 {
		return 0
	}
	if width > maxRenderWidth {
		return maxRenderWidth
	}
	return width
}

// NormalizeRenderQuality 把无效画质回落到默认值。
func NormalizeRenderQuality(quality int) int {
	if quality <= 0 || quality > 100 {
		return defaultImageQuality
	}
	return quality
}

func readCachedImage(path string) ([]byte, bool) {
	info, err := os.Stat(path)
	if err != nil || info.Size() == 0 {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 {
		return nil, false
	}
	return raw, true
}

// flightGroup 是最小实现的 singleflight：
// 同一个 key 上的并发调用只执行一次，其余调用等待并共享结果。
type flightGroup struct {
	mu    sync.Mutex
	calls map[string]*flightCall
}

type flightCall struct {
	wg  sync.WaitGroup
	val []byte
	err error
}

func (g *flightGroup) Do(key string, fn func() ([]byte, error)) ([]byte, error) {
	g.mu.Lock()
	if g.calls == nil {
		g.calls = make(map[string]*flightCall)
	}
	if call, ok := g.calls[key]; ok {
		g.mu.Unlock()
		call.wg.Wait()
		return call.val, call.err
	}
	call := &flightCall{}
	call.wg.Add(1)
	g.calls[key] = call
	g.mu.Unlock()

	call.val, call.err = fn()
	call.wg.Done()

	g.mu.Lock()
	delete(g.calls, key)
	g.mu.Unlock()
	return call.val, call.err
}
