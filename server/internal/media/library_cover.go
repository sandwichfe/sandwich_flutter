package media

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/jpeg"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"embyx/internal/store"
)

// 媒体库默认封面：取库内最近加入的条目海报，竖切成 count 列拼成一张横屏封面。
//
// 每列铺满画布高度、宽度均分，所以 3 张时每列 426×720：条目海报本身是 2:3 竖图，
// 铺进这样的瘦长列只需横向裁掉一点，人物和标题都还在，比均分 16:9 格子（2×2）
// 上下各裁掉三分之一要稳得多。张数上限是 3；不足 3 张时有几张拼几张。
//
// 凑不满 3 张时先确认片子是不是本来就少：只有库里确实没有更多条目才按少数布局拼，
// 否则等海报生成完再拼。
//
// 结果写在 generated/primary/0.jpg，而目录导入与手动上传的封面在 primary/0.jpg。
// 读图链路对媒体库先读 primary、缺失才回退 generated，所以拼图只作兜底：
// 用户一上传封面，拼图自动让位；删掉手动图后又回退到拼图。
const (
	// libraryCoverCount 是拼图的列数上限，取最近的这么多张海报。
	libraryCoverCount = 3
	// coverCanvasW/H 是画布尺寸（16:9），与客户端媒体库卡片的展示比例一致。
	coverCanvasW = 1280
	coverCanvasH = 720
	// libraryCoverSignatureVersion 在布局或尺寸调整时递增，旧签名随之失效并触发重拼。
	libraryCoverSignatureVersion = "v5"
)

// LibraryCoverBuilder 负责生成并登记媒体库拼图封面。
type LibraryCoverBuilder struct {
	images *ImageStore
	store  *store.Store
	// mu 串行化重建：多个库同时拼接会重复争抢 CPU 与磁盘。
	mu sync.Mutex
}

func NewLibraryCoverBuilder(images *ImageStore, st *store.Store) *LibraryCoverBuilder {
	return &LibraryCoverBuilder{images: images, store: st}
}

// Rebuild 重建指定媒体库的拼图封面，返回是否真的重写了图片。
// 触发点在每次扫描结束，重复调用很常见，所以先用候选图的 size+mtime 生成签名，
// 与上次一致时直接跳过，不会反复解码重编码。
func (b *LibraryCoverBuilder) Rebuild(ctx context.Context, lib store.Library) (bool, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	// 多取一些候选：条目海报可能还没生成，需要往后找够 3 张有图的。
	ids, err := b.store.RecentLibraryItemIDs(ctx, lib.ID, libraryCoverCount*5)
	if err != nil {
		return false, err
	}
	if len(ids) == 0 {
		// 库内条目已被清空，旧拼图要删掉，否则会一直显示已经不存在的内容。
		return false, b.removeCover(lib.ID)
	}

	sources := b.pickSources(lib, ids)
	if len(sources) == 0 {
		// 库里有条目但一张海报都没有：拼不出来，也不能把上一次的结果删掉。
		return false, nil
	}
	if len(sources) < libraryCoverCount {
		// 凑不满 3 张时先确认片子是不是本来就少：库里还有条目没出图，
		// 说明海报正在陆续生成，此刻拼会拼出半空的封面，等下次扫描再拼。
		candidates, err := b.store.CountCoverCandidates(ctx, lib.ID)
		if err != nil {
			return false, err
		}
		if candidates > len(sources) {
			return false, nil
		}
	}

	signature := coverSignature(sources)
	if b.readMeta(lib.ID, "sig") == signature {
		return false, nil
	}

	raw, err := composeCover(sources)
	if err != nil {
		return false, fmt.Errorf("拼接媒体库封面失败: %w", err)
	}
	tag, err := b.images.SaveGeneratedImage(lib.ID, "Primary", 0, raw)
	if err != nil {
		return false, err
	}
	// tag 供客户端做缓存键，sig 供下次判断是否需要重拼。
	if err := b.writeMeta(lib.ID, "tag", tag); err != nil {
		return false, err
	}
	if err := b.writeMeta(lib.ID, "sig", signature); err != nil {
		return false, err
	}
	return true, nil
}

// Tag 返回媒体库封面当前生效的标记，客户端把它拼进图片地址做缓存失效。
// 手动/目录封面优先，与读图链路的优先级保持一致。
func (b *LibraryCoverBuilder) Tag(libraryID string) string {
	if info, err := os.Stat(b.images.ItemPath(libraryID, "Primary", 0)); err == nil && info.Size() > 0 {
		return hashTag([]byte(fmt.Sprintf("manual:%d:%d", info.Size(), info.ModTime().UnixNano())))
	}
	return b.readMeta(libraryID, "tag")
}

type coverSource struct {
	itemID string
	path   string
}

// pickSources 按条目实际会显示的那张海报取材，最多取 libraryCoverCount 张。
func (b *LibraryCoverBuilder) pickSources(lib store.Library, ids []string) []coverSource {
	sources := make([]coverSource, 0, libraryCoverCount)
	for _, id := range ids {
		path := b.itemCoverPath(lib, id)
		if path == "" {
			continue
		}
		sources = append(sources, coverSource{itemID: id, path: path})
		if len(sources) == libraryCoverCount {
			break
		}
	}
	return sources
}

// itemCoverPath 的查找顺序与 loadItemImage 一致：库偏好目录图时先找 primary，
// 否则先找 generated，另一侧存在时兜底。返回空表示这个条目还没有任何主图。
func (b *LibraryCoverBuilder) itemCoverPath(lib store.Library, itemID string) string {
	local := b.images.ItemPath(itemID, "Primary", 0)
	generated := b.images.GeneratedPath(itemID, "Primary", 0)
	first, second := local, generated
	if !lib.PreferLocalArtwork {
		first, second = generated, local
	}
	if fileExists(first) {
		return first
	}
	if fileExists(second) {
		return second
	}
	return ""
}

// coverSignature 由参与拼图的条目与图片文件的 size+mtime 组成：
// 换片、换图、重新生成海报都会改变签名，文件没动时保持不变，从而跳过重复拼接。
func coverSignature(sources []coverSource) string {
	var builder strings.Builder
	builder.WriteString(libraryCoverSignatureVersion)
	for _, source := range sources {
		info, err := os.Stat(source.path)
		if err != nil {
			continue
		}
		fmt.Fprintf(&builder, "|%s:%d:%d", source.itemID, info.Size(), info.ModTime().UnixNano())
	}
	return hashTag([]byte(builder.String()))
}

// composeCover 把海报竖切成 count 列拼成一张封面。
func composeCover(sources []coverSource) ([]byte, error) {
	canvas := image.NewRGBA(image.Rect(0, 0, coverCanvasW, coverCanvasH))
	layout := coverLayout(len(sources))
	for index, source := range sources {
		raw, err := os.ReadFile(source.path)
		if err != nil {
			return nil, err
		}
		src, _, err := image.Decode(bytes.NewReader(raw))
		if err != nil {
			return nil, err
		}
		rect := layout[index]
		draw.Draw(canvas, rect, cropToCover(src, rect.Dx(), rect.Dy()), image.Point{}, draw.Src)
	}
	// 单张铺满时没有列缝做分隔，压暗四角让边缘不那么生硬。
	if len(sources) == 1 {
		applyVignette(canvas)
	}

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, canvas, &jpeg.Options{Quality: 88}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// coverLayout 把画布横向均分成 count 列，每列铺满整个高度：
// 3 张时每列 426×720，2:3 的海报只需要横向裁掉一点，纵向几乎无损；
// 2 张时每列 640×720，裁切仍集中在纵向，人物主体基本保留。
// 用整数除法切分，列宽最多差 1px，且最后一列正好落在画布右边界。
func coverLayout(count int) []image.Rectangle {
	if count <= 1 {
		return []image.Rectangle{image.Rect(0, 0, coverCanvasW, coverCanvasH)}
	}
	rects := make([]image.Rectangle, count)
	for index := range rects {
		left := coverCanvasW * index / count
		right := coverCanvasW * (index + 1) / count
		rects[index] = image.Rect(left, 0, right, coverCanvasH)
	}
	return rects
}

// applyVignette 把画面四角压暗、中心保持原样，用于单图铺满的场景。
// 衰减只用到归一化距离的平方，因此完全不需要 sqrt：
// 1280×720 的画布上这一项原本要做 92 万次开方。
func applyVignette(canvas *image.RGBA) {
	bounds := canvas.Bounds()
	centerX := float64(bounds.Dx()) / 2
	centerY := float64(bounds.Dy()) / 2
	maxDistanceSquared := centerX*centerX + centerY*centerY
	if maxDistanceSquared == 0 {
		return
	}
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		deltaY := float64(y) - centerY
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			deltaX := float64(x) - centerX
			distanceSquared := (deltaX*deltaX + deltaY*deltaY) / maxDistanceSquared
			factor := 1 - 0.35*distanceSquared
			offset := canvas.PixOffset(x, y)
			for channel := 0; channel < 3; channel++ {
				canvas.Pix[offset+channel] = uint8(float64(canvas.Pix[offset+channel]) * factor)
			}
		}
	}
}

// cropToCover 等比缩放铺满目标格子，超出部分居中裁掉，避免海报被拉伸变形。
func cropToCover(src image.Image, width, height int) *image.RGBA {
	bounds := src.Bounds()
	srcWidth, srcHeight := bounds.Dx(), bounds.Dy()
	if srcWidth <= 0 || srcHeight <= 0 {
		return image.NewRGBA(image.Rect(0, 0, width, height))
	}
	scale := math.Max(float64(width)/float64(srcWidth), float64(height)/float64(srcHeight))
	scaled := resizeBilinear(src,
		int(math.Round(float64(srcWidth)*scale)),
		int(math.Round(float64(srcHeight)*scale)))
	offsetX := (scaled.Rect.Dx() - width) / 2
	offsetY := (scaled.Rect.Dy() - height) / 2
	out := image.NewRGBA(image.Rect(0, 0, width, height))
	draw.Draw(out, out.Bounds(), scaled, image.Point{X: offsetX, Y: offsetY}, draw.Src)
	return out
}

func (b *LibraryCoverBuilder) readMeta(libraryID, ext string) string {
	raw, err := os.ReadFile(b.images.GeneratedMetaPath(libraryID, "Primary", 0, ext))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func (b *LibraryCoverBuilder) writeMeta(libraryID, ext, value string) error {
	path := b.images.GeneratedMetaPath(libraryID, "Primary", 0, ext)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("创建媒体库封面目录失败: %w", err)
	}
	if err := writeFileAtomic(path, []byte(value)); err != nil {
		return fmt.Errorf("写入媒体库封面元数据失败: %w", err)
	}
	return nil
}

// removeCover 清理拼图与两个边车文件，用于库内条目被清空的场景。
func (b *LibraryCoverBuilder) removeCover(libraryID string) error {
	paths := []string{
		b.images.GeneratedPath(libraryID, "Primary", 0),
		b.images.GeneratedMetaPath(libraryID, "Primary", 0, "tag"),
		b.images.GeneratedMetaPath(libraryID, "Primary", 0, "sig"),
	}
	for _, path := range paths {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}
