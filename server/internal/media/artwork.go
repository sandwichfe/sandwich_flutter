package media

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// LocalArtwork 是同一目录下按 Kodi 命名规范找到的本地图片。
// 与 NFO 一样，只读本地文件，不访问任何网络资源。
type LocalArtwork struct {
	Primary   string
	Backdrops []string
	Banner    string
	Thumb     string
	Logo      string
	ClearArt  string
	Disc      string
}

var artworkExtensions = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true,
}

// FindArtwork 扫描视频所在目录，按优先级匹配图片。
// 高优先级在前：<视频名>-poster > poster > folder > cover > 视频同名 > movie。
func FindArtwork(videoPath string) LocalArtwork {
	dir := filepath.Dir(videoPath)
	return findArtworkIn(dir, filepath.Base(videoPath), readImageIndex(dir))
}

// readImageIndex 枚举目录，返回「小写文件名（不含扩展名）→ 完整路径」。
func readImageIndex(dir string) map[string]string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	images := make(map[string]string, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if !artworkExtensions[ext] {
			continue
		}
		key := strings.ToLower(strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name())))
		images[key] = filepath.Join(dir, entry.Name())
	}
	return images
}

// findArtworkIn 在一份目录图片索引上按优先级匹配，扫描时复用同目录的快照，
// 避免一个目录 100 部片枚举 100 次目录。
func findArtworkIn(dir, fileName string, images map[string]string) LocalArtwork {
	base := strings.ToLower(strings.TrimSuffix(fileName, filepath.Ext(fileName)))
	if len(images) == 0 {
		return LocalArtwork{}
	}

	lookup := func(names ...string) string {
		for _, name := range names {
			if path, ok := images[strings.ToLower(name)]; ok {
				return path
			}
		}
		return ""
	}

	var art LocalArtwork
	art.Primary = lookup(
		base+"-poster", "poster", "folder", "cover", base, "movie",
	)
	art.Banner = lookup(base+"-banner", "banner")
	art.Thumb = lookup(base+"-thumb", "thumb", "landscape", base+"-landscape")
	art.Logo = lookup(base+"-clearlogo", "clearlogo", base+"-logo", "logo")
	art.ClearArt = lookup(base+"-clearart", "clearart", "characterart")
	art.Disc = lookup(base+"-disc", "disc", "discart")

	// 多张背景图：无序号优先，然后 backdrop1..backdrop10。
	if path := lookup(base+"-fanart", "fanart", base+"-backdrop", "backdrop", base+"-background", "background"); path != "" {
		art.Backdrops = append(art.Backdrops, path)
	}
	for index := 1; index <= 10; index++ {
		suffix := strconv.Itoa(index)
		path := lookup(
			base+"-fanart"+suffix, "fanart"+suffix,
			base+"-backdrop"+suffix, "backdrop"+suffix,
			"extrafanart"+suffix,
		)
		if path == "" {
			continue
		}
		// 去重：backdrop 无序号已存在同名文件时跳过。
		duplicate := false
		for _, existing := range art.Backdrops {
			if existing == path {
				duplicate = true
				break
			}
		}
		if !duplicate {
			art.Backdrops = append(art.Backdrops, path)
		}
	}

	return art
}

// readExtraFanartIndex 枚举视频目录下的 extrafanart 子目录，返回
// 「小写目录名 → 按文件名自然排序的图片路径」。
// 支持两种命名：<视频名>-extrafanart（同目录多部片各自独立）与 extrafanart（整目录共用）。
func readExtraFanartIndex(videoDir string) map[string][]string {
	entries, err := os.ReadDir(videoDir)
	if err != nil {
		return nil
	}
	result := make(map[string][]string, 2)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := strings.ToLower(entry.Name())
		if name != "extrafanart" && !strings.HasSuffix(name, "-extrafanart") {
			continue
		}
		if paths := readExtraFanartImages(filepath.Join(videoDir, entry.Name())); len(paths) > 0 {
			result[name] = paths
		}
	}
	return result
}

// readExtraFanartImages 读取一个 extrafanart 目录里的全部图片，按文件名自然排序，
// 这样 fanart2 会排在 fanart10 前面，与目录里看到的顺序一致。
func readExtraFanartImages(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !artworkExtensions[strings.ToLower(filepath.Ext(entry.Name()))] {
			continue
		}
		paths = append(paths, filepath.Join(dir, entry.Name()))
	}
	sort.Slice(paths, func(i, j int) bool {
		return naturalLess(filepath.Base(paths[i]), filepath.Base(paths[j]))
	})
	return paths
}

// naturalLess 按「连续数字段按数值比较」排序，其余字符按 ASCII 比较。
func naturalLess(a, b string) bool {
	a, b = strings.ToLower(a), strings.ToLower(b)
	for i, j := 0, 0; i < len(a) && j < len(b); {
		if isASCIIDigit(a[i]) && isASCIIDigit(b[j]) {
			startI, startJ := i, j
			for i < len(a) && isASCIIDigit(a[i]) {
				i++
			}
			for j < len(b) && isASCIIDigit(b[j]) {
				j++
			}
			if less, decided := compareDigitRuns(a[startI:i], b[startJ:j]); decided {
				return less
			}
			continue
		}
		if a[i] != b[j] {
			return a[i] < b[j]
		}
		i++
		j++
	}
	return len(a) < len(b)
}

// compareDigitRuns 比较两段纯数字：先去掉前导零，再比长度、最后比字典序。
// decided 为 false 表示两段数值相等，交给调用方继续比较后面的字符。
func compareDigitRuns(a, b string) (less, decided bool) {
	a = strings.TrimLeft(a, "0")
	b = strings.TrimLeft(b, "0")
	if len(a) != len(b) {
		return len(a) < len(b), true
	}
	if a == b {
		return false, false
	}
	return a < b, true
}

func isASCIIDigit(value byte) bool {
	return value >= '0' && value <= '9'
}

// FindActorImages 读取 tinyMediaManager 生成的 .actors 目录。
func FindActorImages(videoPath string) map[string]string {
	return readActorIndex(filepath.Dir(videoPath))
}

// actorArtworkSuffixes 是 .actors 目录里演员写真的命名后缀。
var actorArtworkSuffixes = []string{"-fanart", "-backdrop"}

// FindActorFanarts 读取 .actors 目录里 <演员名>-fanart*.jpg / <演员名>-backdrop*.jpg
// 这类写真，返回「演员名 → 写真路径（自然序）」。
func FindActorFanarts(videoPath string) map[string][]string {
	return readActorFanartIndex(filepath.Dir(videoPath))
}

func readActorFanartIndex(videoDir string) map[string][]string {
	dir := filepath.Join(videoDir, ".actors")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	result := make(map[string][]string, 4)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ext := filepath.Ext(entry.Name())
		if !artworkExtensions[strings.ToLower(ext)] {
			continue
		}
		actor, ok := splitActorArtworkName(strings.TrimSuffix(entry.Name(), ext))
		if !ok {
			continue
		}
		result[actor] = append(result[actor], filepath.Join(dir, entry.Name()))
	}
	for actor := range result {
		paths := result[actor]
		// 先按后缀分组（-fanart 在前，-backdrop 在后），组内按自然序，
		// 保证「fanart、fanart2、backdrop1」这样的顺序稳定。
		sort.Slice(paths, func(i, j int) bool {
			left, right := actorArtworkRank(paths[i]), actorArtworkRank(paths[j])
			if left != right {
				return left < right
			}
			return naturalLess(filepath.Base(paths[i]), filepath.Base(paths[j]))
		})
	}
	return result
}

// actorArtworkRank 返回写真后缀的优先级，越小的排在越前面。
func actorArtworkRank(path string) int {
	name := strings.ToLower(filepath.Base(path))
	for index, suffix := range actorArtworkSuffixes {
		if strings.Contains(name, suffix) {
			return index
		}
	}
	return len(actorArtworkSuffixes)
}

// splitActorArtworkName 从 "张三-fanart2" 里取出演员名 "张三"。
// 后缀是纯 ASCII，先剥掉尾部数字再做大小写无关比较，避免整串转小写导致的下标错位。
func splitActorArtworkName(stem string) (string, bool) {
	end := len(stem)
	for end > 0 && isASCIIDigit(stem[end-1]) {
		end--
	}
	base := stem[:end]
	for _, suffix := range actorArtworkSuffixes {
		if len(base) <= len(suffix) {
			continue
		}
		tail := base[len(base)-len(suffix):]
		if !strings.EqualFold(tail, suffix) {
			continue
		}
		actor := strings.TrimSpace(base[:len(base)-len(suffix)])
		if actor == "" {
			return "", false
		}
		return actor, true
	}
	return "", false
}

// readActorIndex 枚举目录下的 .actors 子目录，返回「演员名 → 头像路径」。
func readActorIndex(videoDir string) map[string]string {
	dir := filepath.Join(videoDir, ".actors")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	result := make(map[string]string, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if !artworkExtensions[ext] {
			continue
		}
		name := strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))
		if name == "" {
			continue
		}
		// 写真文件（<演员名>-fanart*.jpg）不算头像，交给 readActorFanartIndex。
		if _, isFanart := splitActorArtworkName(name); isFanart {
			continue
		}
		result[name] = filepath.Join(dir, entry.Name())
	}
	return result
}
