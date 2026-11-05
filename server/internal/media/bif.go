package media

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// BifCache 用 ffmpeg 抽帧并打包成 Emby 客户端可解析的 BIF 索引文件。
//
// 客户端解析规则（emby_pc_player_page.dart / _BifPreviewData）：
//   - 头部固定 64 字节，bytes[0]=0x89，bytes[1..3]="BIF"
//   - 偏移 8：版本号（固定 0），偏移 12：帧数(uint32 LE)，偏移 16：帧间隔(ms，uint32 LE)
//   - 偏移 64 起为索引表，每项 8 字节：绝对时间戳(ms) + 数据偏移
//   - 索引表共 帧数+1 项，最后一项仅用于确定数据区结束位置
type BifCache struct {
	dir        string
	ffmpegPath string

	// 同一条目只允许一个抽帧进程，预生成任务与播放请求不会重复消耗 ffmpeg。
	mu        sync.Mutex
	itemLocks map[string]*sync.Mutex
	// inflight 记录正在后台生成的条目，播放侧重复请求不会反复排任务。
	inflight map[string]bool
	// sem 限制同时运行的 ffmpeg 数量，批量预生成时不会把机器跑满。
	sem chan struct{}
	// baseCtx 是后台生成任务的父 context，进程退出时取消。
	baseCtx context.Context
}

func NewBifCache(dir, ffmpegPath string) *BifCache {
	return &BifCache{
		dir:        dir,
		ffmpegPath: ffmpegPath,
		itemLocks:  make(map[string]*sync.Mutex),
		inflight:   make(map[string]bool),
		sem:        make(chan struct{}, 2),
	}
}

// SetBaseContext 设置后台生成任务的父 context。
func (c *BifCache) SetBaseContext(ctx context.Context) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.baseCtx = ctx
}

// Path 返回指定参数对应的 BIF 缓存路径。
// 文件名带上宽度与抽帧间隔：换参数就是另一个文件，"是否已生成"直接由磁盘回答，
// 不需要在数据库里再维护一个标记字段。
func (c *BifCache) Path(itemID string, width int, intervalMs uint32) string {
	return filepath.Join(c.dir, fmt.Sprintf("%s-w%d-i%d.bif", sanitizeID(itemID), width, intervalMs))
}

// legacyPath 是早期不带参数后缀的缓存名，仅在升级后用于继续复用老文件。
func (c *BifCache) legacyPath(itemID string) string {
	return filepath.Join(c.dir, sanitizeID(itemID)+".bif")
}

// RemoveItem 删除某个条目的全部 BIF 缓存。
// 缓存文件名带宽度与抽帧间隔，同一部片可能同时存在多个变体，统一按前缀清理；
// 条目被删除或改名后如果不清，这些文件会永久留在缓存目录里。
func (c *BifCache) RemoveItem(itemID string) {
	prefix := sanitizeID(itemID)
	entries, err := os.ReadDir(c.dir)
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
		_ = os.Remove(filepath.Join(c.dir, name))
	}
}

// freshFile 判断文件是否可复用：内容非空，且不比源文件旧（片源换过就要重做）。
func freshFile(path, sourcePath string) bool {
	info, err := os.Stat(path)
	if err != nil || info.Size() == 0 {
		return false
	}
	if sourcePath == "" {
		return true
	}
	src, err := os.Stat(sourcePath)
	if err != nil {
		return true
	}
	return !src.ModTime().After(info.ModTime())
}

// cacheHit 在 freshFile 基础上再校验 BIF 布局：旧版本会把别家格式的 BIF
// （索引时间戳是帧序号）原样拷进缓存，这类文件必须当作未命中重建。
func cacheHit(path, sourcePath string) bool {
	return usableBIF(path) && freshFile(path, sourcePath)
}

// reuse 返回当前条目可复用的缓存：先找参数完全一致的文件，再退到早期无参数命名。
// 老文件名里没有参数信息，命中一次后就改名成带参数的名字，避免反复判定。
func (c *BifCache) reuse(itemID, sourcePath, target string) string {
	if cacheHit(target, sourcePath) {
		return target
	}
	legacy := c.legacyPath(itemID)
	if sameFilePath(legacy, target) || !cacheHit(legacy, sourcePath) {
		return ""
	}
	if err := os.Rename(legacy, target); err == nil {
		return target
	}
	return legacy
}

// anyVariant 返回同一条目其它参数的可用缓存，供播放侧避免为宽度差异重新解码整部影片。
func (c *BifCache) anyVariant(itemID, sourcePath string) string {
	entries, err := os.ReadDir(c.dir)
	if err != nil {
		return ""
	}
	prefix := sanitizeID(itemID)
	best := ""
	var bestTime time.Time
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		rest := strings.TrimPrefix(name, prefix)
		// 只认 prefix.bif 与 prefix-w<宽>-i<间隔>.bif，避免误命中前缀相同的其它条目。
		if rest == name || !strings.HasSuffix(strings.ToLower(rest), ".bif") {
			continue
		}
		if rest != ".bif" && !strings.HasPrefix(rest, "-w") {
			continue
		}
		path := filepath.Join(c.dir, name)
		if !cacheHit(path, sourcePath) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if best == "" || info.ModTime().After(bestTime) {
			best, bestTime = path, info.ModTime()
		}
	}
	return best
}

// FFmpegPath 暴露配置的 ffmpeg 可执行文件，供任务启动前做可用性检查。
func (c *BifCache) FFmpegPath() string {
	return c.ffmpegPath
}

// Ensure 返回 BIF 缓存文件路径；缓存缺失时现场生成。
func (c *BifCache) Ensure(ctx context.Context, itemID, sourcePath string, intervalMs uint32, width int) (string, error) {
	path, _, _, err := c.Generate(ctx, itemID, sourcePath, BifOptions{
		IntervalMs: intervalMs,
		Width:      width,
		// 播放只是拿来当进度条预览，能用其它宽度的现成缓存就不必再解一遍全片。
		ReuseAnyVariant: true,
	})
	return path, err
}

// Lookup 只查已有缓存，不做任何生成，命中时返回可直接使用的 BIF 路径。
func (c *BifCache) Lookup(itemID, sourcePath string, intervalMs uint32, width int) string {
	if intervalMs == 0 {
		intervalMs = 10000
	}
	if width <= 0 {
		width = 320
	}
	target := c.Path(itemID, width, intervalMs)
	if hit := c.reuse(itemID, sourcePath, target); hit != "" {
		return hit
	}
	// 播放只是画进度条预览，其它宽度的现成缓存同样够用。
	return c.anyVariant(itemID, sourcePath)
}

// EnsureAsync 返回可用的 BIF 路径；缓存缺失时只登记一次后台生成任务并返回 false。
//
// 这样首次播放不会被 ffmpeg 抽帧阻塞（原来一个请求可能要等几分钟），
// 播放器先降级成普通进度条，生成完成后再打开就有预览图。
func (c *BifCache) EnsureAsync(itemID, sourcePath string, intervalMs uint32, width int) (string, bool) {
	if hit := c.Lookup(itemID, sourcePath, intervalMs, width); hit != "" {
		return hit, true
	}

	key := sanitizeID(itemID)
	c.mu.Lock()
	if c.inflight[key] {
		c.mu.Unlock()
		return "", false
	}
	c.inflight[key] = true
	baseCtx := c.baseCtx
	c.mu.Unlock()

	go func() {
		defer func() {
			c.mu.Lock()
			delete(c.inflight, key)
			c.mu.Unlock()
		}()
		if baseCtx == nil {
			baseCtx = context.Background()
		}
		if _, err := c.Ensure(baseCtx, itemID, sourcePath, intervalMs, width); err != nil {
			log.Printf("后台生成 BIF 失败 item=%s: %v", itemID, err)
		}
	}()
	return "", false
}

// BifOptions 汇总生成参数，避免调用点出现一长串位置参数。
type BifOptions struct {
	IntervalMs uint32
	Width      int
	// Force 为 true 时忽略已有缓存重新抽帧。
	Force bool
	// ReuseAnyVariant 允许复用同一条目其它参数的缓存（播放侧使用）。
	ReuseAnyVariant bool
	// OnProgress 以已解码的媒体时间（毫秒）回调，调用方据此换算条目内进度。
	OnProgress func(elapsedMs int64)
}

// Generate 生成 BIF 缓存，返回文件路径、帧数以及是否复用了已有文件（未执行抽帧）。
func (c *BifCache) Generate(ctx context.Context, itemID, sourcePath string, opts BifOptions) (string, int, bool, error) {
	intervalMs := opts.IntervalMs
	if intervalMs == 0 {
		intervalMs = 10000
	}
	width := opts.Width
	if width <= 0 {
		width = 320
	}
	force := opts.Force
	target := c.Path(itemID, width, intervalMs)

	if !force {
		if hit := c.reuse(itemID, sourcePath, target); hit != "" {
			return hit, countBIFrames(hit), true, nil
		}
		if opts.ReuseAnyVariant {
			if hit := c.anyVariant(itemID, sourcePath); hit != "" {
				return hit, countBIFrames(hit), true, nil
			}
		}
	}
	if sourcePath == "" {
		return "", 0, false, fmt.Errorf("条目缺少源文件路径")
	}
	if _, err := os.Stat(sourcePath); err != nil {
		return "", 0, false, fmt.Errorf("源文件不可读: %w", err)
	}

	unlock := c.lockItem(itemID)
	defer unlock()

	// 双检：等锁期间可能已被其他请求生成。
	if !force {
		if hit := c.reuse(itemID, sourcePath, target); hit != "" {
			return hit, countBIFrames(hit), true, nil
		}
	}

	// 媒体目录里已经有预生成的 BIF 时直接拿来用，网络盘上可以省掉整段抽帧。
	// 强制重生成时跳过复用，否则新间隔不会生效。
	// 注意这里只判断「不比片源旧」，格式由 importLocalBIF 解析并重写：
	// 第三方 BIF 的索引时间戳是帧序号，原样复制会让预览永远停在最后一帧。
	if local := FindLocalBIF(sourcePath); !force && local != "" && !sameFilePath(local, target) && freshFile(local, sourcePath) {
		if imported, frames, err := c.importLocalBIF(itemID, width, local); err == nil {
			return imported, frames, true, nil
		}
	}

	select {
	case c.sem <- struct{}{}:
		defer func() { <-c.sem }()
	case <-ctx.Done():
		return "", 0, false, ctx.Err()
	}

	tempDir, err := os.MkdirTemp(c.dir, "bif-*")
	if err != nil {
		return "", 0, false, fmt.Errorf("创建临时目录失败: %w", err)
	}
	defer os.RemoveAll(tempDir)

	// 抽帧需要解码整部影片：预生成遇到 4K/网络盘长片往往超过 10 分钟，
	// 所以只在播放侧保留短超时，预生成放宽到 60 分钟。
	timeout := 10 * time.Minute
	if force {
		timeout = 60 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	seconds := float64(intervalMs) / 1000
	// format=yuvj420p 是必需的：ffmpeg 7 的 mjpeg 编码器拒绝非 full-range 的 YUV。
	// 片长不足一个抽帧间隔时 fps 过滤器一帧都不输出，编码器仍会按默认参数初始化并直接失败，
	// 导致下面「至少取首帧」的兜底根本走不到。
	args := []string{
		"-y",
		"-v", "error",
		"-nostats",
		"-i", sourcePath,
		"-vf", fmt.Sprintf("fps=1/%g,scale=%d:-2,format=yuvj420p", seconds, width),
		"-q:v", "5",
		"-progress", "pipe:1",
		filepath.Join(tempDir, "frame_%05d.jpg"),
	}
	if err := runFFmpeg(ctx, c.ffmpegPath, args, opts.OnProgress); err != nil {
		return "", 0, false, err
	}

	frames, err := collectFrames(tempDir)
	if err != nil {
		return "", 0, false, err
	}
	if len(frames) == 0 {
		// 短视频不足一个抽帧间隔时，至少取首帧，避免整个进度预览失效。
		frames, err = extractSingleFrame(ctx, c.ffmpegPath, sourcePath, tempDir, width)
		if err != nil {
			return "", 0, false, err
		}
	}
	if len(frames) == 0 {
		return "", 0, false, fmt.Errorf("未生成任何缩略图帧")
	}

	packed := PackBIF(frames, intervalMs)
	if err := writeFileAtomic(target, packed); err != nil {
		return "", 0, false, err
	}
	return target, len(frames), false, nil
}

// runFFmpeg 启动 ffmpeg 并同步消费 -progress 输出。
// 必须持续读 stdout，否则管道写满会让 ffmpeg 阻塞，进度也就永远不动。
func runFFmpeg(ctx context.Context, ffmpegPath string, args []string, onProgress func(elapsedMs int64)) error {
	cmd := exec.CommandContext(ctx, ffmpegPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("无法读取 ffmpeg 进度: %w", err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("ffmpeg 启动失败（请检查 ffmpeg 路径）: %w", err)
	}

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		if onProgress == nil {
			continue
		}
		if elapsedMs, ok := parseFFmpegProgress(scanner.Text()); ok {
			onProgress(elapsedMs)
		}
	}

	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("ffmpeg 抽帧失败: %w (%s)", err, truncate(strings.TrimSpace(stderr.String()), 400))
	}
	return nil
}

// parseFFmpegProgress 解析 -progress 的 key=value 行。
// out_time_ms 的历史单位其实是微秒，优先使用含义明确的 out_time_us。
func parseFFmpegProgress(line string) (int64, bool) {
	line = strings.TrimSpace(line)
	var raw string
	switch {
	case strings.HasPrefix(line, "out_time_us="):
		raw = strings.TrimPrefix(line, "out_time_us=")
	case strings.HasPrefix(line, "out_time_ms="):
		raw = strings.TrimPrefix(line, "out_time_ms=")
	default:
		return 0, false
	}

	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || value < 0 {
		// 起播阶段会输出 out_time_us=N/A，忽略即可。
		return 0, false
	}
	return value / 1000, true
}

// countBIFrames 从 BIF 头部读取帧数（uint32 小端），读不到时返回 0。
// 先读偏移 8（本项目旧版布局的帧数），为 0 时回退偏移 12（标准布局的帧数），
// 两种布局都能读出正确帧数，避免把已有缓存算成 0 帧。
func countBIFrames(path string) int {
	file, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer file.Close()

	header := make([]byte, 20)
	if _, err := io.ReadFull(file, header); err != nil {
		return 0
	}
	if count := int(binary.LittleEndian.Uint32(header[8:12])); count > 0 {
		return count
	}
	return int(binary.LittleEndian.Uint32(header[12:16]))
}

// lockItem 为单个条目加进程内互斥锁，避免并发请求重复抽同一个视频。
func (c *BifCache) lockItem(itemID string) func() {
	c.mu.Lock()
	lock, ok := c.itemLocks[itemID]
	if !ok {
		lock = &sync.Mutex{}
		c.itemLocks[itemID] = lock
	}
	c.mu.Unlock()

	lock.Lock()
	return lock.Unlock
}

// writeFileAtomic 先写临时文件再改名，避免并发读取方拿到写了一半的文件
// （BIF 缓存、扫描导入的图片都用它）。
func writeFileAtomic(target string, data []byte) error {
	temp, err := os.CreateTemp(filepath.Dir(target), "atomic-*.tmp")
	if err != nil {
		return fmt.Errorf("创建临时文件失败: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)

	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return fmt.Errorf("写入文件失败: %w", err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return fmt.Errorf("写入文件失败: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("写入文件失败: %w", err)
	}
	// CreateTemp 默认 0600，图片需要保持原来的 0644。
	if err := os.Chmod(tempPath, 0o644); err != nil {
		return fmt.Errorf("设置文件权限失败: %w", err)
	}
	if err := os.Rename(tempPath, target); err != nil {
		return fmt.Errorf("重命名临时文件失败: %w", err)
	}
	return nil
}

// sameFilePath 判断两个路径是否指向同一文件，避免把缓存文件当成媒体目录里的 BIF 再复制。
func sameFilePath(a, b string) bool {
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	if errA != nil || errB != nil {
		return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
	}
	return strings.EqualFold(filepath.Clean(absA), filepath.Clean(absB))
}

// extractSingleFrame 用于时长不足一个抽帧间隔的视频。
func extractSingleFrame(ctx context.Context, ffmpegPath, sourcePath, dir string, width int) ([][]byte, error) {
	target := filepath.Join(dir, "single.jpg")
	args := []string{
		"-y", "-v", "error",
		"-i", sourcePath,
		"-vf", fmt.Sprintf("scale=%d:-2", width),
		"-frames:v", "1",
		"-q:v", "5",
		target,
	}
	if output, err := exec.CommandContext(ctx, ffmpegPath, args...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("ffmpeg 抽取首帧失败: %w (%s)", err, truncate(string(output), 400))
	}
	raw, err := os.ReadFile(target)
	if err != nil {
		return nil, fmt.Errorf("读取首帧失败: %w", err)
	}
	return [][]byte{raw}, nil
}

func collectFrames(dir string) ([][]byte, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "frame_*.jpg"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)

	frames := make([][]byte, 0, len(paths))
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		frames = append(frames, raw)
	}
	return frames, nil
}

const (
	// bifHeaderLength 是 BIF 固定头部长度，索引表从 64 字节之后开始。
	bifHeaderLength = 64
	// bifIndexEntryLen 是索引项长度：帧时间戳(ms) + 数据偏移。
	bifIndexEntryLen = 8
)

// bifLayout 描述「帧数 / 帧间隔」在头部里的偏移。
// 标准 BIF（Emby、Infuse 等实现）是 12 / 16；本项目早期版本写在 8 / 12，两种都要能读，
// 否则历史缓存会被判成无效而全部重抽。
type bifLayout struct {
	countOffset    int
	intervalOffset int
}

// bifLayouts 按优先级排列：先按标准布局解析，再退回本项目旧版布局。
var bifLayouts = []bifLayout{
	{countOffset: 12, intervalOffset: 16},
	{countOffset: 8, intervalOffset: 12},
}

// PackBIF 按标准 BIF 布局拼装文件内容。
//   - 0..3：魔数 0x89 'B' 'I' 'F'，4..7：固定换行符 0d 0a 1a 0a
//   - 8..11：版本号，必须为 0（客户端会先把这里当帧数读，写非 0 会被误判）
//   - 12..15：帧数，16..19：帧间隔(ms)
//   - 64 起为索引表，每项 8 字节：帧时间戳(ms) + 数据偏移，共 帧数+1 项
func PackBIF(frames [][]byte, intervalMs uint32) []byte {
	indexLength := (len(frames) + 1) * bifIndexEntryLen
	dataStart := bifHeaderLength + indexLength

	total := dataStart
	for _, frame := range frames {
		total += len(frame)
	}

	buf := make([]byte, total)
	buf[0] = 0x89
	copy(buf[1:4], "BIF")
	copy(buf[4:8], []byte{0x0d, 0x0a, 0x1a, 0x0a})
	binary.LittleEndian.PutUint32(buf[8:12], 0)
	binary.LittleEndian.PutUint32(buf[12:16], uint32(len(frames)))
	binary.LittleEndian.PutUint32(buf[16:20], intervalMs)

	offset := dataStart
	for index, frame := range frames {
		entry := bifHeaderLength + index*bifIndexEntryLen
		binary.LittleEndian.PutUint32(buf[entry:entry+4], uint32(index)*intervalMs)
		binary.LittleEndian.PutUint32(buf[entry+4:entry+8], uint32(offset))
		copy(buf[offset:], frame)
		offset += len(frame)
	}

	// 哨兵项：时间戳无效，偏移指向数据区末尾。
	sentinel := bifHeaderLength + len(frames)*bifIndexEntryLen
	binary.LittleEndian.PutUint32(buf[sentinel:sentinel+4], 0xFFFFFFFF)
	binary.LittleEndian.PutUint32(buf[sentinel+4:sentinel+8], uint32(offset))

	return buf
}

// UnpackBIF 解析 BIF 内容，兼容标准布局与本项目旧版布局，返回帧数据和帧间隔。
// 只做结构校验（索引偏移、JPEG 头），不解释时间戳：第三方 BIF 的索引时间戳可能是帧序号，
// 由调用方按间隔重新打包。
func UnpackBIF(data []byte) ([][]byte, uint32, error) {
	if len(data) < bifHeaderLength+2*bifIndexEntryLen || data[0] != 0x89 || string(data[1:4]) != "BIF" {
		return nil, 0, fmt.Errorf("不是有效的 BIF 文件")
	}
	for _, layout := range bifLayouts {
		if frames, interval, err := readBIFFrames(data, layout); err == nil {
			return frames, interval, nil
		}
	}
	return nil, 0, fmt.Errorf("无法识别的 BIF 布局")
}

// readBIFFrames 按指定布局切出全部帧，布局不匹配时返回错误。
func readBIFFrames(data []byte, layout bifLayout) ([][]byte, uint32, error) {
	count := int(binary.LittleEndian.Uint32(data[layout.countOffset : layout.countOffset+4]))
	interval := binary.LittleEndian.Uint32(data[layout.intervalOffset : layout.intervalOffset+4])
	if count <= 0 || interval == 0 {
		return nil, 0, fmt.Errorf("BIF 头部字段无效")
	}
	if bifHeaderLength+(count+1)*bifIndexEntryLen > len(data) {
		return nil, 0, fmt.Errorf("BIF 帧数超出文件长度")
	}

	frames := make([][]byte, 0, count)
	for index := 0; index < count; index++ {
		entry := bifHeaderLength + index*bifIndexEntryLen
		start := int(binary.LittleEndian.Uint32(data[entry+4 : entry+8]))
		end := int(binary.LittleEndian.Uint32(data[entry+bifIndexEntryLen+4 : entry+bifIndexEntryLen+8]))
		if start < bifHeaderLength || end-start < 2 || end > len(data) {
			return nil, 0, fmt.Errorf("BIF 索引偏移无效")
		}
		if data[start] != 0xFF || data[start+1] != 0xD8 {
			return nil, 0, fmt.Errorf("BIF 帧数据不是 JPEG")
		}
		frames = append(frames, data[start:end])
	}
	return frames, interval, nil
}

// usableBIF 判断文件是不是本项目能直接用的 BIF：布局正确，且索引时间戳按 index*intervalMs 递增。
// 早期版本会把媒体目录里别家生成的 BIF 原样拷进缓存（索引时间戳是帧序号 0,1,2…），
// 客户端按毫秒二分查找会永远落在最后一帧，这类文件必须重建。
func usableBIF(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()

	header := make([]byte, bifHeaderLength+2*bifIndexEntryLen)
	if _, err := io.ReadFull(file, header); err != nil {
		return false
	}
	if header[0] != 0x89 || string(header[1:4]) != "BIF" {
		return false
	}

	for _, layout := range bifLayouts {
		count := int(binary.LittleEndian.Uint32(header[layout.countOffset : layout.countOffset+4]))
		interval := binary.LittleEndian.Uint32(header[layout.intervalOffset : layout.intervalOffset+4])
		if count <= 0 || interval == 0 {
			continue
		}
		first := binary.LittleEndian.Uint32(header[bifHeaderLength : bifHeaderLength+4])
		if first != 0 {
			continue
		}
		if count > 1 {
			second := binary.LittleEndian.Uint32(header[bifHeaderLength+bifIndexEntryLen:])
			if second != interval {
				continue
			}
		}
		return true
	}
	return false
}

// importLocalBIF 把媒体目录里现成的 BIF 规范化后写进缓存，返回缓存路径与帧数。
// 只重写头部与索引、不重新解码，网络盘上可以省掉整段抽帧。
// 缓存名用 BIF 自身的间隔，避免把 10s 间隔的文件当成 4s 间隔复用。
func (c *BifCache) importLocalBIF(itemID string, width int, local string) (string, int, error) {
	raw, err := os.ReadFile(local)
	if err != nil {
		return "", 0, err
	}
	frames, interval, err := UnpackBIF(raw)
	if err != nil {
		return "", 0, err
	}

	target := c.Path(itemID, width, interval)
	if sameFilePath(local, target) {
		// 媒体目录就是缓存目录时不要覆盖用户原有的文件。
		return "", 0, fmt.Errorf("本地 BIF 已位于缓存目录")
	}
	if err := writeFileAtomic(target, PackBIF(frames, interval)); err != nil {
		return "", 0, err
	}
	return target, len(frames), nil
}

func truncate(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	return text[:limit] + "..."
}

// FindLocalBIF 在视频所在目录查找预先存在的 BIF 文件。
// 常见命名：<视频名>.bif、<视频名>-<宽>-<间隔>.bif（如 xxx-320-10.bif）。
func FindLocalBIF(videoPath string) string {
	base := strings.TrimSuffix(videoPath, filepath.Ext(videoPath))
	if info, err := os.Stat(base + ".bif"); err == nil && !info.IsDir() && info.Size() > 0 {
		return base + ".bif"
	}

	dir := filepath.Dir(videoPath)
	prefix := strings.ToLower(filepath.Base(base))
	if prefix == "" {
		return ""
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".bif") {
			continue
		}
		stem := strings.ToLower(strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name())))
		if !strings.HasPrefix(stem, prefix) {
			continue
		}
		info, err := entry.Info()
		if err != nil || info.Size() == 0 {
			continue
		}
		return filepath.Join(dir, entry.Name())
	}
	return ""
}
