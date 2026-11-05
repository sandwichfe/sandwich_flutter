package media

import (
	"context"
	"fmt"
	"image"
	_ "image/jpeg"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// 支持的生成图片类型。海报是竖版 2:3，封面（背景图）是横版 16:9。
const (
	ArtworkPrimary  = "Primary"
	ArtworkBackdrop = "Backdrop"
	ArtworkThumb    = "Thumb"
)

// artworkDefaults 描述各类图片的默认输出尺寸。
var artworkDefaults = map[string][2]int{
	ArtworkPrimary:  {600, 900},
	ArtworkBackdrop: {1280, 720},
	ArtworkThumb:    {640, 360},
}

// sniffRatios 是自动嗅探时取样画面的位置（占总时长的比例）。
// 只取中间段，避开片头片尾的纯黑帧与字幕滚动画面。
var sniffRatios = []float64{0.10, 0.25, 0.40, 0.55, 0.70, 0.85}

// sniffConcurrency 限制嗅探时同时运行的 ffmpeg 数量。
// 候选点本身只有几个，全开收益有限；此外并发越多，越容易争抢同一文件所在磁盘的带宽。
const sniffConcurrency = 3

// ArtworkOptions 汇总一次生成请求的参数。
type ArtworkOptions struct {
	SourcePath   string
	RunTimeTicks int64
	// PositionTicks > 0 时按指定进度取帧；为 0 时用嗅探自动挑一帧。
	PositionTicks int64
	// Types 为空时按海报 + 封面处理。
	Types []string
	// Width 为 0 时按图片类型使用默认宽度。
	Width int
}

// ArtworkResult 返回生成结果，PositionTicks 是实际取帧位置，便于前端回显。
type ArtworkResult struct {
	Tags          map[string]string
	PositionTicks int64
	Sniffed       bool
}

// ArtworkGenerator 用 ffmpeg 从视频画面生成海报、封面和缩略图。
type ArtworkGenerator struct {
	images     *ImageStore
	prober     *Prober
	ffmpegPath string

	// 同一条目只允许一个生成进程，避免重复点击同时起多个 ffmpeg。
	itemLocks keyedMutex
}

func NewArtworkGenerator(images *ImageStore, prober *Prober, ffmpegPath string) *ArtworkGenerator {
	return &ArtworkGenerator{
		images:     images,
		prober:     prober,
		ffmpegPath: ffmpegPath,
	}
}

// Generate 按参数抽帧并落盘，返回每张图片对应的 image tag。
func (g *ArtworkGenerator) Generate(ctx context.Context, itemID string, opts ArtworkOptions) (ArtworkResult, error) {
	types := normalizeArtworkTypes(opts.Types)
	if len(types) == 0 {
		return ArtworkResult{}, fmt.Errorf("请至少选择一种要生成的图片")
	}
	if opts.SourcePath == "" {
		return ArtworkResult{}, fmt.Errorf("该条目没有可用的视频文件")
	}
	if _, err := os.Stat(opts.SourcePath); err != nil {
		return ArtworkResult{}, fmt.Errorf("视频文件不可读: %w", err)
	}
	if _, err := exec.LookPath(g.ffmpegPath); err != nil {
		return ArtworkResult{}, fmt.Errorf(
			"找不到 ffmpeg（当前配置：%q），请安装 ffmpeg 或用 EMBYX_FFMPEG / config.yaml 指定完整路径",
			g.ffmpegPath,
		)
	}

	durationSeconds := float64(opts.RunTimeTicks) / 10_000_000
	if durationSeconds <= 0 {
		// 入库时 ffprobe 失败才没有时长，这里再补一次探测，避免只能取首帧。
		if info, err := g.prober.Probe(ctx, opts.SourcePath); err == nil {
			durationSeconds = float64(info.DurationTicks) / 10_000_000
		}
	}
	// 排查"生成出来不是本片画面"时，先确认这条日志里的源文件是不是目标视频。
	log.Printf("[artwork] 生成请求 item=%s 源文件=%q 时长=%s 类型=%v",
		itemID, opts.SourcePath, formatClock(durationSeconds), types)

	unlock := g.lockItem(itemID)
	defer unlock()

	result := ArtworkResult{Tags: make(map[string]string, len(types))}
	positionSeconds := float64(opts.PositionTicks) / 10_000_000
	if opts.PositionTicks <= 0 {
		result.Sniffed = true
		positionSeconds = g.sniffPosition(ctx, opts.SourcePath, durationSeconds)
	}
	if positionSeconds < 0 {
		positionSeconds = 0
	}
	if durationSeconds > 0 && positionSeconds > durationSeconds {
		positionSeconds = durationSeconds * 0.95
	}
	result.PositionTicks = int64(math.Round(positionSeconds * 10_000_000))
	log.Printf("[artwork] 截取源头 item=%s 源文件=%q 位置=%s 嗅探=%v 时长=%s",
		itemID, opts.SourcePath, formatClock(positionSeconds), result.Sniffed, formatClock(durationSeconds))

	for _, imageType := range types {
		width, height := artworkSize(imageType, opts.Width)
		// 先抽到临时文件，再统一走 SaveItemImage 转码落盘：
		// 一个槽位只有一张图，生成就是覆盖这张图，不再分 generated 目录。
		dir, err := os.MkdirTemp("", "embyx-artwork-*")
		if err != nil {
			return result, err
		}
		target := filepath.Join(dir, "frame.jpg")
		err = g.extractFrame(ctx, opts.SourcePath, positionSeconds, width, height, target)
		if err != nil {
			os.RemoveAll(dir)
			return result, fmt.Errorf("生成%s失败: %w", artworkTypeLabel(imageType), err)
		}
		raw, readErr := os.ReadFile(target)
		os.RemoveAll(dir)
		if readErr != nil {
			return result, fmt.Errorf("读取生成的%s失败: %w", artworkTypeLabel(imageType), readErr)
		}
		tag, err := g.images.SaveItemImage(itemID, imageType, 0, raw)
		if err != nil {
			return result, err
		}
		if err := g.images.WriteOrigin(itemID, imageType, 0, OriginGenerate); err != nil {
			log.Printf("[artwork] 写入图片来源失败 item=%s 类型=%s: %v", itemID, imageType, err)
		}
		log.Printf("[artwork] 落盘 item=%s 类型=%s 目标=%q 字节=%d tag=%s",
			itemID, imageType, g.images.ItemPath(itemID, imageType, 0), len(raw), tag)
		result.Tags[imageType] = tag
	}
	return result, nil
}

// formatClock 把秒数格式化成 时:分:秒，便于日志里直读进度。
// 调用方多为非负值，负数（探测失败）统一显示 00:00:00。
func formatClock(seconds float64) string {
	if seconds <= 0 {
		return "00:00:00"
	}
	total := int(math.Round(seconds))
	return fmt.Sprintf("%02d:%02d:%02d", total/3600, total%3600/60, total%60)
}

// sniffPosition 在几个候选时间点抽帧，挑画面信息量最大的一帧。
// 打分同时惩罚过暗和过亮的画面（黑场、白场、字幕淡入淡出）。
// 各候选点互不依赖，按 sniffConcurrency 并发执行。
func (g *ArtworkGenerator) sniffPosition(ctx context.Context, sourcePath string, durationSeconds float64) float64 {
	if durationSeconds <= 1 {
		return 0
	}
	tempDir, err := os.MkdirTemp("", "embyx-artwork-*")
	if err != nil {
		return durationSeconds * 0.30
	}
	defer os.RemoveAll(tempDir)

	// 每个 worker 只写自己下标的分数，互不重叠，因此不需要加锁。
	// -1 表示该候选点抽帧或解码失败。
	scores := make([]float64, len(sniffRatios))
	for index := range scores {
		scores[index] = -1
	}

	sem := make(chan struct{}, sniffConcurrency)
	var wg sync.WaitGroup
	for index, ratio := range sniffRatios {
		wg.Add(1)
		sem <- struct{}{}
		go func(index int, ratio float64) {
			defer wg.Done()
			defer func() { <-sem }()

			position := durationSeconds * ratio
			candidate := filepath.Join(tempDir, "sniff_"+strconv.Itoa(index)+".jpg")
			if err := g.extractFrame(ctx, sourcePath, position, 320, 0, candidate); err != nil {
				return
			}
			scores[index] = frameScore(candidate)
		}(index, ratio)
	}
	wg.Wait()

	bestIndex := -1
	for index, score := range scores {
		// 严格大于：分数相同时保留更靠前的候选点，与串行遍历的取舍保持一致。
		if score >= 0 && (bestIndex < 0 || score > scores[bestIndex]) {
			bestIndex = index
		}
	}
	if bestIndex < 0 {
		return durationSeconds * 0.30
	}
	return durationSeconds * sniffRatios[bestIndex]
}

// frameScore 用灰度标准差作为"细节丰富度"，再按过暗/过亮像素占比做惩罚。
func frameScore(path string) float64 {
	file, err := os.Open(path)
	if err != nil {
		return -1
	}
	defer file.Close()

	img, _, err := image.Decode(file)
	if err != nil {
		return -1
	}
	bounds := img.Bounds()
	if bounds.Dx() == 0 || bounds.Dy() == 0 {
		return -1
	}

	// 采样步长随分辨率放大，评分结果稳定且不必逐像素遍历。
	step := bounds.Dx() / 80
	if step < 1 {
		step = 1
	}

	var sum, sumSquare float64
	total, extreme := 0, 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y += step {
		for x := bounds.Min.X; x < bounds.Max.X; x += step {
			r, g, b, _ := img.At(x, y).RGBA()
			luma := 0.299*float64(r>>8) + 0.587*float64(g>>8) + 0.114*float64(b>>8)
			sum += luma
			sumSquare += luma * luma
			if luma < 20 || luma > 235 {
				extreme++
			}
			total++
		}
	}
	if total == 0 {
		return -1
	}
	mean := sum / float64(total)
	stdDev := math.Sqrt(math.Max(0, sumSquare/float64(total)-mean*mean))
	return stdDev * (1 - float64(extreme)/float64(total))
}

// PreviewFrame 抽取指定时间点的一帧用于滑块预览：只返回 JPEG 字节，
// 不写图片目录，也不回写任何图片标记，纯粹给编辑弹窗看效果。
// 走临时文件而不是 pipe，是为了复用 extractFrame 的裁剪与错误处理。
func (g *ArtworkGenerator) PreviewFrame(ctx context.Context, sourcePath string, positionSeconds float64, maxWidth int) ([]byte, error) {
	if sourcePath == "" {
		return nil, fmt.Errorf("该条目没有可用的视频文件")
	}
	if positionSeconds < 0 {
		positionSeconds = 0
	}
	dir, err := os.MkdirTemp("", "embyx-frame-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)

	target := filepath.Join(dir, "frame.jpg")
	if err := g.extractFrame(ctx, sourcePath, positionSeconds, maxWidth, 0, target); err != nil {
		return nil, err
	}
	return os.ReadFile(target)
}

// extractFrame 抽取指定时间点的一帧，按目标尺寸居中裁切。
// -ss 放在 -i 之前是快速定位，长片上只解码关键帧附近，足够选海报用。
func (g *ArtworkGenerator) extractFrame(ctx context.Context, sourcePath string, seconds float64, width, height int, target string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	args := []string{
		"-y", "-v", "error",
		"-ss", strconv.FormatFloat(seconds, 'f', 3, 64),
		"-i", sourcePath,
		"-frames:v", "1",
	}
	if width > 0 && height > 0 {
		args = append(args, "-vf", fmt.Sprintf(
			"scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d",
			width, height, width, height,
		))
	} else if width > 0 {
		args = append(args, "-vf", fmt.Sprintf("scale=%d:-2", width))
	}
	args = append(args, "-q:v", "3", target)

	if output, err := exec.CommandContext(ctx, g.ffmpegPath, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("ffmpeg 抽帧失败: %w (命令: %s %s) (输出: %s)",
			err, g.ffmpegPath, strings.Join(args, " "), truncate(string(output), 300))
	}
	info, err := os.Stat(target)
	if err != nil || info.Size() == 0 {
		os.Remove(target)
		return fmt.Errorf("ffmpeg 未输出图片（时间点可能超出片长）")
	}
	return nil
}

func (g *ArtworkGenerator) lockItem(itemID string) func() {
	return g.itemLocks.Lock(itemID)
}

// normalizeArtworkTypes 去重并只保留支持的类型，顺序固定为海报 → 封面 → 缩略图。
func normalizeArtworkTypes(values []string) []string {
	if len(values) == 0 {
		return []string{ArtworkPrimary, ArtworkBackdrop}
	}
	selected := map[string]bool{}
	for _, value := range values {
		switch NormalizeImageType(value) {
		case ArtworkPrimary:
			selected[ArtworkPrimary] = true
		case ArtworkBackdrop:
			selected[ArtworkBackdrop] = true
		case ArtworkThumb:
			selected[ArtworkThumb] = true
		}
	}
	result := make([]string, 0, len(selected))
	for _, imageType := range []string{ArtworkPrimary, ArtworkBackdrop, ArtworkThumb} {
		if selected[imageType] {
			result = append(result, imageType)
		}
	}
	return result
}

// imageTypeNames 是客户端传来的图片类型（大小写与别名都不统一）到 Emby 规范名的映射。
// HTTP 层与生成器共用这一份，避免两处各自维护、改一处漏一处。
var imageTypeNames = map[string]string{
	"primary":    ArtworkPrimary,
	"poster":     ArtworkPrimary,
	"backdrop":   ArtworkBackdrop,
	"cover":      ArtworkBackdrop,
	"fanart":     ArtworkBackdrop,
	"thumb":      ArtworkThumb,
	"landscape":  ArtworkThumb,
	"logo":       "Logo",
	"banner":     "Banner",
	"disc":       "Disc",
	"art":        "Art",
	"chapter":    "Chapter",
	"screenshot": "Screenshot",
}

// NormalizeImageType 把图片类型归一成 Emby 规范名，不认识的返回空串。
func NormalizeImageType(value string) string {
	return imageTypeNames[strings.ToLower(strings.TrimSpace(value))]
}

func artworkSize(imageType string, width int) (int, int) {
	size := artworkDefaults[imageType]
	// 限制上限，避免异常参数让 ffmpeg 输出超大的图。
	if width > 2000 {
		width = 2000
	}
	if width < 120 {
		return size[0], size[1]
	}
	height := int(math.Round(float64(width) * float64(size[1]) / float64(size[0])))
	return width, height
}

func artworkTypeLabel(imageType string) string {
	switch imageType {
	case ArtworkPrimary:
		return "海报"
	case ArtworkBackdrop:
		return "封面"
	case ArtworkThumb:
		return "缩略图"
	}
	return imageType
}
