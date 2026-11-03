package media

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io/fs"
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

// Scan 遍历媒体目录并入库；重复执行是幂等的（ID 由路径派生）。
func (s *Scanner) Scan(ctx context.Context, roots []string, logf func(string, ...any)) (int, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}

	imported := 0
	for order, root := range roots {
		libraryID := stableID("library:" + root)
		libraryName := filepath.Base(root)
		if err := s.store.UpsertLibrary(ctx, libraryID, libraryName, "movies", root, order); err != nil {
			return imported, err
		}
		logf("扫描媒体库 %s (%s)", libraryName, root)

		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
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

			item, probeErr := s.buildItem(ctx, libraryID, path, logf)
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
		if err != nil && err != context.Canceled {
			return imported, err
		}
	}
	logf("扫描完成，共导入 %d 个条目", imported)
	return imported, nil
}

func (s *Scanner) buildItem(ctx context.Context, libraryID, path string, logf func(string, ...any)) (*store.Item, error) {
	probe, err := s.prober.Probe(ctx, path)
	if err != nil {
		return nil, err
	}

	fileTitle, fileYear := parseFileName(filepath.Base(path))
	item := &store.Item{
		ID: stableID("item:" + path),
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

func stableID(seed string) string {
	sum := sha1.Sum([]byte(seed))
	return hex.EncodeToString(sum[:16])
}

func (s *Scanner) String() string {
	return fmt.Sprintf("Scanner{prober=%s}", s.prober.ffprobePath)
}
