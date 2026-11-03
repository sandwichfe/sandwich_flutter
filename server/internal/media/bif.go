package media

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// BifCache 用 ffmpeg 抽帧并打包成 Emby 客户端可解析的 BIF 索引文件。
//
// 客户端解析规则（emby_pc_player_page.dart / _BifPreviewData）：
//   - 头部固定 64 字节，bytes[0]=0x89，bytes[1..3]="BIF"
//   - 偏移 12：帧数(uint32 LE)，偏移 16：时间戳乘数(ms，uint32 LE)
//   - 偏移 64 起为索引表，每项 8 字节：timestamp + 数据偏移
//   - 索引表共 帧数+1 项，最后一项仅用于确定数据区结束位置
type BifCache struct {
	dir        string
	ffmpegPath string

	mu sync.Mutex
}

func NewBifCache(dir, ffmpegPath string) *BifCache {
	return &BifCache{dir: dir, ffmpegPath: ffmpegPath}
}

func (c *BifCache) Path(itemID string) string {
	return filepath.Join(c.dir, sanitizeID(itemID)+".bif")
}

// Ensure 返回 BIF 缓存文件路径；缓存缺失时现场生成。
func (c *BifCache) Ensure(ctx context.Context, itemID, sourcePath string, intervalMs uint32, width int) (string, error) {
	target := c.Path(itemID)
	if info, err := os.Stat(target); err == nil && info.Size() > 0 {
		return target, nil
	}
	if sourcePath == "" {
		return "", fmt.Errorf("条目缺少源文件路径")
	}
	if _, err := os.Stat(sourcePath); err != nil {
		return "", fmt.Errorf("源文件不可读: %w", err)
	}
	if intervalMs == 0 {
		intervalMs = 10000
	}
	if width <= 0 {
		width = 320
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// 双检：等锁期间可能已被其他请求生成。
	if info, err := os.Stat(target); err == nil && info.Size() > 0 {
		return target, nil
	}

	// 媒体目录里已经有预生成的 BIF 时直接拿来用，网络盘上可以省掉整段抽帧。
	if local := FindLocalBIF(sourcePath); local != "" {
		if err := copyFile(local, target); err == nil {
			return target, nil
		}
	}

	tempDir, err := os.MkdirTemp(c.dir, "bif-*")
	if err != nil {
		return "", fmt.Errorf("创建临时目录失败: %w", err)
	}
	defer os.RemoveAll(tempDir)

	seconds := float64(intervalMs) / 1000
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	args := []string{
		"-y",
		"-v", "error",
		"-i", sourcePath,
		"-vf", fmt.Sprintf("fps=1/%g,scale=%d:-2", seconds, width),
		"-q:v", "5",
		filepath.Join(tempDir, "frame_%05d.jpg"),
	}
	if output, err := exec.CommandContext(ctx, c.ffmpegPath, args...).CombinedOutput(); err != nil {
		return "", fmt.Errorf("ffmpeg 抽帧失败: %w (%s)", err, truncate(string(output), 400))
	}

	frames, err := collectFrames(tempDir)
	if err != nil {
		return "", err
	}
	if len(frames) == 0 {
		// 短视频不足一个抽帧间隔时，至少取首帧，避免整个进度预览失效。
		frames, err = extractSingleFrame(ctx, c.ffmpegPath, sourcePath, tempDir, width)
		if err != nil {
			return "", err
		}
	}
	if len(frames) == 0 {
		return "", fmt.Errorf("未生成任何缩略图帧")
	}

	packed := PackBIF(frames, intervalMs)
	if err := os.WriteFile(target, packed, 0o644); err != nil {
		return "", fmt.Errorf("写入 BIF 失败: %w", err)
	}
	return target, nil
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

// PackBIF 按 BIF 规范拼装文件内容。
func PackBIF(frames [][]byte, intervalMs uint32) []byte {
	const headerLength = 64
	const indexEntryLength = 8

	indexLength := (len(frames) + 1) * indexEntryLength
	dataStart := headerLength + indexLength

	total := dataStart
	for _, frame := range frames {
		total += len(frame)
	}

	buf := make([]byte, total)
	buf[0] = 0x89
	copy(buf[1:4], "BIF")
	// 4..7 版本号，8..11 保留，按规范留 0。
	binary.LittleEndian.PutUint32(buf[12:16], uint32(len(frames)))
	binary.LittleEndian.PutUint32(buf[16:20], intervalMs)

	offset := dataStart
	for index, frame := range frames {
		entry := headerLength + index*indexEntryLength
		binary.LittleEndian.PutUint32(buf[entry:entry+4], uint32(index)*intervalMs)
		binary.LittleEndian.PutUint32(buf[entry+4:entry+8], uint32(offset))
		copy(buf[offset:], frame)
		offset += len(frame)
	}

	// 哨兵项：时间戳无效，偏移指向数据区末尾。
	sentinel := headerLength + len(frames)*indexEntryLength
	binary.LittleEndian.PutUint32(buf[sentinel:sentinel+4], 0xFFFFFFFF)
	binary.LittleEndian.PutUint32(buf[sentinel+4:sentinel+8], uint32(offset))

	return buf
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

func copyFile(source, target string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(target)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Sync()
}
