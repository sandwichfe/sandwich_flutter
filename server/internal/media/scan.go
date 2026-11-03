package media

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"embyx/internal/dto"
	"embyx/internal/store"
)

var videoExtensions = map[string]bool{
	".mkv": true, ".mp4": true, ".avi": true, ".mov": true,
	".wmv": true, ".ts": true, ".m2ts": true, ".flv": true, ".webm": true, ".rmvb": true,
}

var skipDirs = map[string]bool{
	"@eadir": true, "#recycle": true, "$recycle.bin": true,
	"system volume information": true, ".git": true,
}

// 匹配 "标题 (2023)" / "标题.2023.1080p" 中的年份。
var yearPattern = regexp.MustCompile(`(?:^|[.\-_\[\]( ])((?:19|20)\d{2})(?:[.\-_\[\]) ]|$)`)

type Scanner struct {
	store  *store.Store
	prober *Prober
	images *ImageStore
}

func NewScanner(s *store.Store, prober *Prober, images *ImageStore) *Scanner {
	return &Scanner{store: s, prober: prober, images: images}
}

// ScanAll 扫描数据库中配置的全部媒体库。
func (s *Scanner) ScanAll(ctx context.Context, logf func(string, ...any)) (int, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}

	libraries, err := s.store.Libraries(ctx)
	if err != nil {
		return 0, err
	}
	if len(libraries) == 0 {
		logf("尚未配置媒体库，跳过扫描")
		return 0, nil
	}

	total := 0
	for _, lib := range libraries {
		imported, scanErr := s.ScanLibrary(ctx, lib, logf)
		total += imported
		if scanErr != nil {
			logf("扫描媒体库 %s 失败: %v", lib.Name, scanErr)
		}
	}
	logf("全部扫描完成，共导入 %d 个条目", total)
	return total, nil
}

// ScanLibrary 扫描单个媒体库的所有目录；重复执行是幂等的（条目 ID 由路径派生）。
func (s *Scanner) ScanLibrary(ctx context.Context, lib store.Library, logf func(string, ...any)) (int, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	if len(lib.Paths) == 0 {
		logf("媒体库 %s 没有配置目录，跳过", lib.Name)
		return 0, nil
	}

	imported := 0
	for _, root := range lib.Paths {
		if info, err := os.Stat(root); err != nil || !info.IsDir() {
			logf("媒体库 %s 的目录不可访问，跳过: %s", lib.Name, root)
			continue
		}
		logf("扫描媒体库 %s (%s)", lib.Name, root)

		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return nil
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if entry.IsDir() {
				if skipDirs[strings.ToLower(entry.Name())] {
					return fs.SkipDir
				}
				return nil
			}
			if !videoExtensions[strings.ToLower(filepath.Ext(path))] {
				return nil
			}

			item, probeErr := s.buildItem(ctx, lib.ID, path, logf)
			if probeErr != nil {
				logf("跳过 %s: %v", path, probeErr)
				return nil
			}
			if err := s.store.UpsertItem(ctx, item); err != nil {
				logf("入库失败 %s: %v", path, err)
				return nil
			}
			imported++
			return nil
		})
		if err != nil && !errors.Is(err, context.Canceled) {
			return imported, err
		}
	}
	logf("媒体库 %s 扫描完成，共处理 %d 个条目", lib.Name, imported)
	return imported, nil
}

func (s *Scanner) buildItem(ctx context.Context, libraryID, path string, logf func(string, ...any)) (*store.Item, error) {
	probe, err := s.prober.Probe(ctx, path)
	if err != nil {
		return nil, err
	}

	fileTitle, fileYear := parseFileName(filepath.Base(path))
	item := &store.Item{
		ID: store.StableID("item:" + path),
		// Emby 语义里媒体库是条目的父节点，客户端浏览库内内容时传 ParentId=<库ID>。
		LibraryID:      libraryID,
		ParentID:       libraryID,
		Type:           "Movie",
		Name:           fileTitle,
		SortName:       fileTitle,
		Path:           path,
		Container:      probe.Container,
		Size:           probe.Size,
		Bitrate:        probe.Bitrate,
		RunTimeTicks:   probe.DurationTicks,
		Width:          probe.Width,
		Height:         probe.Height,
		MediaStreams:   probe.Streams,
		Genres:         []string{},
		Tags:           []string{},
		Studios:        []dto.NameIDPair{},
		People:         []dto.PersonDto{},
		Chapters:       []dto.ChapterInfo{},
		ProviderIDs:    map[string]string{},
		ExternalURLs:   []dto.ExternalURL{},
		ImageTags:      map[string]string{},
		BackdropTags:   []string{},
		ScreenshotTags: []string{},
	}
	if fileYear != 0 {
		year := fileYear
		item.ProductionYear = &year
	}

	// NFO 优先于文件名推断；解析失败时保留文件名结果。
	if nfoPath := FindNFO(path); nfoPath != "" {
		nfo, err := ParseNFO(nfoPath)
		if err != nil {
			logf("NFO 解析失败 %s: %v", nfoPath, err)
		} else {
			applyNFO(item, nfo)
		}
	}
	if item.Name == "" {
		item.Name = fileTitle
		item.SortName = fileTitle
	}
	if item.SortName == "" {
		item.SortName = item.Name
	}
	if item.DateCreated == "" {
		item.DateCreated = store.NowISO()
	}

	// 本地图片按 Kodi 命名规则导入，演员头像取 .actors 目录。
	s.importArtwork(item, path, logf)
	logf("入库 %s", item.Name)
	return item, nil
}

// parseFileName 从文件名推断标题与年份，覆盖常见的 "标题 (2023)" 与 "标题.2023.1080p" 写法。
func parseFileName(fileName string) (string, int) {
	base := strings.TrimSuffix(fileName, filepath.Ext(fileName))
	base = strings.TrimSpace(base)

	year := 0
	title := base
	if match := yearPattern.FindStringSubmatchIndex(base); match != nil {
		year = parseInt(base[match[2]:match[3]])
		title = strings.TrimSpace(base[:match[0]])
		if title == "" {
			title = strings.TrimSpace(base[match[1]:])
		}
	}
	title = cleanTitle(title)
	if title == "" {
		title = base
	}
	return title, year
}

var titleSeparators = regexp.MustCompile(`[._]+`)

func cleanTitle(value string) string {
	cleaned := titleSeparators.ReplaceAllString(value, " ")
	cleaned = strings.ReplaceAll(cleaned, "  ", " ")
	return strings.Trim(cleaned, " .-_[](){}")
}

func (s *Scanner) String() string {
	return fmt.Sprintf("Scanner{prober=%s}", s.prober.ffprobePath)
}
