package media

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"embyx/internal/dto"
	"embyx/internal/store"
)

// applyNFO 用 NFO 元数据覆盖文件名推断出的字段。
// 所有字段都以"非空才覆盖"为原则，避免缺项把已有值清空。
func applyNFO(item *store.Item, nfo *NFOData) {
	if nfo.Title != "" {
		item.Name = nfo.Title
		item.SortName = nfo.Title
	}
	if nfo.SortTitle != "" {
		item.SortName = nfo.SortTitle
	}
	if nfo.Plot != "" {
		item.Overview = nfo.Plot
	} else if nfo.Outline != "" {
		item.Overview = nfo.Outline
	}

	if nfo.Year > 0 {
		year := nfo.Year
		item.ProductionYear = &year
	}
	if date := nfo.NormalizedPremiereDate(); date != "" {
		item.PremiereDate = date
	}
	if date := nfo.NormalizedDateAdded(); date != "" {
		item.DateCreated = date
	}
	if nfo.MPAA != "" {
		item.OfficialRating = nfo.MPAA
	}
	if nfo.Rating > 0 {
		rating := nfo.Rating
		item.CommunityRating = &rating
	}

	if len(nfo.Genres) > 0 {
		item.Genres = nfo.Genres
	}
	if len(nfo.Tags) > 0 {
		item.Tags = nfo.Tags
	}
	if len(nfo.Studios) > 0 {
		studios := make([]dto.NameIDPair, 0, len(nfo.Studios))
		for _, name := range nfo.Studios {
			studios = append(studios, dto.NameIDPair{ID: store.StableID("studio:" + name), Name: name})
		}
		item.Studios = studios
	}

	if people := buildPeople(nfo); len(people) > 0 {
		item.People = people
	}
	if providers := normalizeProviderIDs(nfo.UniqueIDs); len(providers) > 0 {
		item.ProviderIDs = providers
	}

	// ffprobe 已经拿到时长时以它为准，NFO 的 runtime 只是兜底。
	if item.RunTimeTicks == 0 && nfo.RuntimeMinutes > 0 {
		item.RunTimeTicks = int64(nfo.RuntimeMinutes) * 60 * 10_000_000
	}
}

func buildPeople(nfo *NFOData) []dto.PersonDto {
	people := make([]dto.PersonDto, 0, len(nfo.Actors)+len(nfo.Directors)+len(nfo.Writers))
	seen := map[string]bool{}

	appendPerson := func(name, role, kind string) {
		name = strings.TrimSpace(name)
		if name == "" {
			return
		}
		key := kind + ":" + name
		if seen[key] {
			return
		}
		seen[key] = true
		people = append(people, dto.PersonDto{
			ID:   store.StableID("person:" + name),
			Name: name,
			Role: role,
			Type: kind,
		})
	}

	for _, director := range nfo.Directors {
		appendPerson(director, "", "Director")
	}
	for _, writer := range nfo.Writers {
		appendPerson(writer, "", "Writer")
	}
	for _, actor := range nfo.Actors {
		appendPerson(actor.Name, actor.Role, "Actor")
	}
	return people
}

// normalizeProviderIDs 把 NFO 的 uniqueid 类型转换成 Emby 的键名（Tmdb / Imdb / Tvdb）。
func normalizeProviderIDs(ids map[string]string) map[string]string {
	result := make(map[string]string, len(ids))
	for key, value := range ids {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "tmdb", "tmdbid":
			result["Tmdb"] = value
		case "imdb", "imdbid":
			result["Imdb"] = value
		case "tvdb", "tvdbid":
			result["Tvdb"] = value
		case "douban", "doubanid":
			result["Douban"] = value
		default:
			result[titleCase(strings.TrimSpace(key))] = value
		}
	}
	return result
}

// importArtwork 把目录里的本地图片拷进自管图片目录，并把 tag 回写到条目。
// 条目图片被锁定、或库选了"视频生成的封面"时跳过目录图，避免覆盖用户/生成结果；
// 人物头像有自己的锁，不受条目锁与库开关影响。
func (s *Scanner) importArtwork(item *store.Item, videoPath string, logf func(string, ...any)) {
	// 同目录的图片与演员头像只枚举一次：网络盘上这两次 ReadDir 是扫描里最贵的一环。
	dir := filepath.Dir(videoPath)
	snapshot := s.snapshotDir(dir)
	art := findArtworkIn(dir, filepath.Base(videoPath), snapshot.images)

	if s.images.ItemLocked(item.ID) {
		// 用户锁定了这个条目的图片：扫描不再用目录图覆盖。
		logf("图片已锁定，跳过目录图 %s", videoPath)
	} else if !s.libraryPreferLocal(item.LibraryID) {
		logf("封面来源为视频生成，跳过目录图 %s", videoPath)
	} else {
		// 目录图回退（poster/folder/cover/movie）会让同目录多个视频共用一张图，
		// 这行日志能直接看出每个条目的海报究竟来自哪个文件。
		primarySource := art.Primary
		if primarySource == "" {
			primarySource = "（未找到）"
		}
		logf("匹配图片 %s → 海报=%s 背景=%d 张", videoPath, primarySource, len(art.Backdrops))

		if art.Primary != "" {
			if tag, err := s.saveArtwork(item.ID, "Primary", 0, art.Primary); err == nil {
				item.ImageTags["Primary"] = tag
			} else {
				logf("导入海报失败 %s: %v", art.Primary, err)
			}
		}

		for index, path := range art.Backdrops {
			tag, err := s.saveArtwork(item.ID, "Backdrop", index, path)
			if err != nil {
				logf("导入背景图失败 %s: %v", path, err)
				continue
			}
			item.BackdropTags = append(item.BackdropTags, tag)
		}

		extraImages := []struct {
			imageType string
			path      string
		}{
			{"Thumb", art.Thumb},
			{"Logo", art.Logo},
			{"Banner", art.Banner},
			{"Disc", art.Disc},
			{"Art", art.ClearArt},
		}
		for _, extra := range extraImages {
			if extra.path == "" {
				continue
			}
			if tag, err := s.saveArtwork(item.ID, extra.imageType, 0, extra.path); err == nil {
				item.ImageTags[extra.imageType] = tag
			} else {
				logf("导入 %s 失败 %s: %v", extra.imageType, extra.path, err)
			}
		}
	}

	// .actors/<演员名>.jpg 由 tinyMediaManager 一类工具生成。
	for name, path := range snapshot.actors {
		personID := store.StableID("person:" + name)
		// 人物头像可能有自己的锁（人物不受条目锁影响）。
		if s.images.ItemLocked(personID) {
			continue
		}
		tag, err := s.saveArtwork(personID, "Primary", 0, path)
		if err != nil {
			continue
		}
		for index := range item.People {
			if item.People[index].Name != name {
				continue
			}
			item.People[index].PrimaryImageTag = tag
			item.People[index].ImageTags = map[string]string{"Primary": tag}
		}
	}
}

// libraryPreferLocal 查询媒体库的封面来源偏好；查不到时按目录图处理，
// 与升级前的默认行为保持一致。
func (s *Scanner) libraryPreferLocal(libraryID string) bool {
	lib, err := s.store.LibraryByID(context.Background(), libraryID)
	if err != nil {
		return true
	}
	return lib.PreferLocalArtwork
}

// saveArtwork 幂等导入：目标文件比源文件新时直接复用，避免每次扫描重复转码。
// 是否允许覆盖由调用方按图片锁与库偏好决定，这里只负责落盘。
func (s *Scanner) saveArtwork(itemID, imageType string, index int, sourcePath string) (string, error) {
	target := s.images.ItemPath(itemID, imageType, index)
	unlock := s.lockArtworkTarget(target)
	defer unlock()

	if isUpToDate(target, sourcePath) {
		if raw, err := os.ReadFile(target); err == nil {
			return hashTag(raw), nil
		}
	}

	raw, err := os.ReadFile(sourcePath)
	if err != nil {
		return "", err
	}
	tag, err := s.images.SaveItemImage(itemID, imageType, index, raw)
	if err != nil {
		return "", err
	}
	if err := s.images.WriteOrigin(itemID, imageType, index, OriginImport); err != nil {
		return tag, err
	}
	return tag, nil
}

// lockArtworkTarget 按目标文件加锁。演员头像由多个条目共用同一路径
// （images/<personID>/primary/0.jpg），并发扫描时不加锁会重复转码，
// 非原子写还可能让 HTTP 读到半截文件。
func (s *Scanner) lockArtworkTarget(target string) func() {
	return s.artLocks.Lock(target)
}

func isUpToDate(target, source string) bool {
	targetInfo, err := os.Stat(target)
	if err != nil {
		return false
	}
	sourceInfo, err := os.Stat(source)
	if err != nil {
		return false
	}
	return !targetInfo.ModTime().Before(sourceInfo.ModTime())
}
