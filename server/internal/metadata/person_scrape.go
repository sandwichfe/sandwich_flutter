package metadata

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"

	"embyx/internal/media"
	"embyx/internal/store"
)

// PersonScraper 把 TMDB 的演员资料与图片写进本地库。
// 只做「取数据 + 落库」，不做任务调度；批量与单个触发都走 PersonScrapeJobManager。
type PersonScraper struct {
	store        *store.Store
	images       *media.ImageStore
	client       *Client
	maxBackdrops int
	logf         func(string, ...any)

	// creditsCache 缓存影片演职员表：同一部片的演员往往是同一批人，
	// 不缓存的话一部片会被重复拉 N 次，白白增加请求量与触发限流的风险。
	creditsMu    sync.Mutex
	creditsCache map[string]*MovieCredits
}

// creditsCacheLimit 限制缓存条目数，避免大库刮削时内存无限增长。
const creditsCacheLimit = 500

func NewPersonScraper(st *store.Store, images *media.ImageStore, client *Client, maxBackdrops int) *PersonScraper {
	return &PersonScraper{
		store:        st,
		images:       images,
		client:       client,
		maxBackdrops: maxBackdrops,
		logf:         func(string, ...any) {},
		creditsCache: make(map[string]*MovieCredits, 64),
	}
}

// movieCredits 带缓存地读取影片演职员表。
func (s *PersonScraper) movieCredits(ctx context.Context, movieID string) (*MovieCredits, error) {
	s.creditsMu.Lock()
	cached, ok := s.creditsCache[movieID]
	s.creditsMu.Unlock()
	if ok {
		return cached, nil
	}

	credits, err := s.client.MovieCredits(ctx, movieID)
	if err != nil {
		return nil, err
	}
	s.creditsMu.Lock()
	if len(s.creditsCache) < creditsCacheLimit {
		s.creditsCache[movieID] = credits
	}
	s.creditsMu.Unlock()
	return credits, nil
}

// SetLogger 让调用方接入统一日志。
func (s *PersonScraper) SetLogger(logf func(string, ...any)) {
	if logf != nil {
		s.logf = logf
	}
}

// ScrapeOutcome 是单个人物的刮削结果。
type ScrapeOutcome struct {
	// State 取值 matched / ambiguous / not_found，ambiguous 不会写任何资料。
	State   string
	Updated bool
	Images  int
}

// Scrape 处理一位演员：先确定 TMDB 身份，再写资料与图片。
func (s *PersonScraper) Scrape(ctx context.Context, target store.PersonScrapeTarget, force bool) (ScrapeOutcome, error) {
	outcome := ScrapeOutcome{}
	tmdbID, state := s.resolveTmdbID(ctx, target)
	if tmdbID == "" {
		outcome.State = state
		if err := s.store.MarkPersonMatchState(ctx, target.ID, state); err != nil {
			return outcome, err
		}
		return outcome, nil
	}

	person, err := s.client.Person(ctx, tmdbID)
	if err != nil {
		return outcome, fmt.Errorf("读取演员 %s 失败: %w", target.Name, err)
	}

	providerIDs := map[string]string{"Tmdb": tmdbID}
	// external_ids 失败不影响主流程，只是少了 IMDb 编号。
	if ids, idsErr := s.client.PersonExternalIDs(ctx, tmdbID); idsErr == nil && ids.IMDBID != "" {
		providerIDs["Imdb"] = ids.IMDBID
	}

	updated, err := s.store.ApplyScrapedPerson(ctx, target.ID, store.ScrapedPersonData{
		Overview:    strings.TrimSpace(person.Biography),
		BirthDate:   strings.TrimSpace(person.Birthday),
		Gender:      genderLabel(person.Gender),
		ProviderIDs: providerIDs,
	}, force)
	if err != nil {
		return outcome, err
	}
	outcome.State = store.PersonMatchMatched
	outcome.Updated = updated

	images, err := s.applyImages(ctx, target.ID, tmdbID, person, force)
	if err != nil {
		// 图片失败不回滚文字资料，记录后继续跑下一个人。
		s.logf("刮削图片失败 %s: %v", target.Name, err)
	}
	outcome.Images = images
	return outcome, nil
}

// resolveTmdbID 决定这位演员对应 TMDB 的哪个人。
// 顺序：已有编号 → 按关联影片的 credits 反查 → 姓名搜索 + 作品交叉验证。
func (s *PersonScraper) resolveTmdbID(ctx context.Context, target store.PersonScrapeTarget) (string, string) {
	if id := strings.TrimSpace(target.ProviderIDs["Tmdb"]); id != "" {
		return id, store.PersonMatchMatched
	}

	needle := normalizePersonName(target.Name)
	for _, movieID := range target.MovieTmdb {
		credits, err := s.movieCredits(ctx, movieID)
		if err != nil {
			continue
		}
		for _, credit := range credits.Cast {
			if credit.ID > 0 && normalizePersonName(credit.Name) == needle {
				return strconv.Itoa(credit.ID), store.PersonMatchMatched
			}
		}
		for _, credit := range credits.Crew {
			if credit.ID > 0 && normalizePersonName(credit.Name) == needle {
				return strconv.Itoa(credit.ID), store.PersonMatchMatched
			}
		}
	}

	results, err := s.client.SearchPerson(ctx, target.Name)
	if err != nil {
		return "", store.PersonMatchAmbiguous
	}
	candidates := make([]SearchResult, 0, len(results))
	for _, result := range results {
		if result.ID > 0 && normalizePersonName(result.Name) == needle {
			candidates = append(candidates, result)
		}
	}
	if len(candidates) == 0 {
		return "", store.PersonMatchNotFound
	}
	if len(candidates) == 1 {
		return strconv.Itoa(candidates[0].ID), store.PersonMatchMatched
	}

	// 同名多人：用「已知作品」和这位演员演过的片子求交集，唯一最高分才采信。
	bestID, bestScore, tie := 0, -1, false
	for _, candidate := range candidates {
		score := 0
		for _, known := range candidate.KnownFor {
			title := known.Title
			if title == "" {
				title = known.Name
			}
			for _, movie := range target.MovieNames {
				if normalizePersonName(title) == normalizePersonName(movie) {
					score += 10
				}
			}
		}
		switch {
		case score > bestScore:
			bestID, bestScore, tie = candidate.ID, score, false
		case score == bestScore:
			tie = true
		}
	}
	if bestScore <= 0 || tie {
		return "", store.PersonMatchAmbiguous
	}
	return strconv.Itoa(bestID), store.PersonMatchMatched
}

// applyImages 下载头像与写真。图片被锁定时整段跳过（用户手动锁优先）。
// personID 是本地演员 ID（图片落盘用），tmdbID 是 TMDB 侧编号（接口查询用）。
func (s *PersonScraper) applyImages(ctx context.Context, personID, tmdbID string, person *Person, force bool) (int, error) {
	locked, err := s.store.ImageLocked(ctx, personID)
	if err != nil {
		return 0, err
	}
	if locked {
		return 0, nil
	}

	saved := 0
	if person.ProfilePath != "" && s.shouldReplaceImage(personID, "Primary", 0, force) {
		if tag, err := s.saveImage(ctx, personID, "Primary", 0, person.ProfilePath); err == nil {
			if tagErr := s.store.SetPersonImageTag(ctx, personID, "Primary", 0, tag); tagErr == nil {
				saved++
			}
		}
	}

	if s.maxBackdrops <= 0 {
		return saved, nil
	}
	images, err := s.client.PersonImages(ctx, tmdbID)
	if err != nil {
		return saved, err
	}
	// 头像那张不重复当写真；按票数排序取前 N 张。
	profiles := make([]Image, 0, len(images.Profiles))
	for _, profile := range images.Profiles {
		if profile.FilePath == "" || profile.FilePath == person.ProfilePath {
			continue
		}
		profiles = append(profiles, profile)
	}
	sort.SliceStable(profiles, func(i, j int) bool {
		if profiles[i].VoteAverage == profiles[j].VoteAverage {
			return profiles[i].VoteCount > profiles[j].VoteCount
		}
		return profiles[i].VoteAverage > profiles[j].VoteAverage
	})
	if len(profiles) > s.maxBackdrops {
		profiles = profiles[:s.maxBackdrops]
	}
	tags := make([]string, 0, len(profiles))
	for index, profile := range profiles {
		if !s.shouldReplaceImage(personID, "Backdrop", index, force) {
			// 用户上传的写真要保留，用原有 tag 占住槽位。
			tags = append(tags, s.existingImageTag(personID, "Backdrop", index))
			continue
		}
		tag, err := s.saveImage(ctx, personID, "Backdrop", index, profile.FilePath)
		if err != nil {
			continue
		}
		tags = append(tags, tag)
		saved++
	}
	if err := s.store.SetPersonBackdropTags(ctx, personID, tags); err != nil {
		return saved, err
	}
	// 上次比这次多时，把多余的文件也删掉（用户上传/生成的图不在清理范围）。
	if err := s.images.PruneItemImages(personID, "Backdrop", len(tags)); err != nil {
		s.logf("清理演员多余写真失败 %s: %v", personID, err)
	}
	return saved, nil
}

// existingImageTag 读取已落盘图片的 tag（文件名即内容哈希），用于保留用户上传的图。
func (s *PersonScraper) existingImageTag(personID, imageType string, index int) string {
	path := s.images.ItemPath(personID, imageType, index)
	base := filepath.Base(path)
	return strings.TrimSuffix(base, filepath.Ext(base))
}

// shouldReplaceImage 决定某个槽位能否被刮削结果覆盖：
// 没有图当然写；用户上传/生成的图不覆盖；其余（本地导入、上次刮削）允许刷新。
func (s *PersonScraper) shouldReplaceImage(personID, imageType string, index int, force bool) bool {
	if !s.images.HasItemImage(personID, imageType, index) {
		return true
	}
	origin := s.images.ReadOrigin(personID, imageType, index)
	if origin == media.OriginUpload || origin == media.OriginGenerate {
		return false
	}
	return true
}

func (s *PersonScraper) saveImage(ctx context.Context, personID, imageType string, index int, filePath string) (string, error) {
	raw, err := s.client.DownloadImage(ctx, filePath, "w780")
	if err != nil {
		return "", err
	}
	tag, err := s.images.SaveItemImage(personID, imageType, index, raw)
	if err != nil {
		return "", err
	}
	// 标记来源：下次刮削可覆盖，手动上传的则不会被动。
	_ = s.images.WriteOrigin(personID, imageType, index, media.OriginAuto)
	return tag, nil
}

func genderLabel(gender int) string {
	switch gender {
	case 1:
		return "Female"
	case 2:
		return "Male"
	case 3:
		return "NonBinary"
	}
	return ""
}

// normalizePersonName 统一中英文姓名比较用的形式：去空格、间隔号、大小写差异。
func normalizePersonName(value string) string {
	replacer := strings.NewReplacer(" ", "", "　", "", "·", "", ".", "", "•", "")
	return strings.ToLower(replacer.Replace(strings.TrimSpace(value)))
}
