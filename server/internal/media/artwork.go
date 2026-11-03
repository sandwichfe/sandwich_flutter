package media

import (
	"os"
	"path/filepath"
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
	base := strings.ToLower(strings.TrimSuffix(filepath.Base(videoPath), filepath.Ext(videoPath)))

	entries, err := os.ReadDir(dir)
	if err != nil {
		return LocalArtwork{}
	}

	// 小写文件名（不含扩展名）→ 完整路径，避免重复遍历目录。
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

// FindActorImages 读取 tinyMediaManager 生成的 .actors 目录。
func FindActorImages(videoPath string) map[string]string {
	dir := filepath.Join(filepath.Dir(videoPath), ".actors")
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
		result[name] = filepath.Join(dir, entry.Name())
	}
	return result
}
