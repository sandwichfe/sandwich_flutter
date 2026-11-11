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

// PersonScraper 把多来源的演员资料与图片写进本地库。
// 只做「取数据 + 合并 + 落库」，不做任务调度；批量与单个触发都走 PersonScrapeJobManager。
type PersonScraper struct {
	store        *store.Store
	images       *media.ImageStore
	client       *Client
	maxBackdrops int
	logf         func(string, ...any)

	// sources 按优先级从高到低排列（AV 档案站 > TMDB）。
	sources []PersonSource
	// remote 只用于下载外部来源的头像，和 TMDB 客户端的图片基址互不影响。
	remote *personSourceClient

	// creditsCache 缓存影片演职员表：同一部片的演员往往是同一批人，
	// 不缓存的话一部片会被重复拉 N 次，白白增加请求量与触发限流的风险。
	creditsMu    sync.Mutex
	creditsCache map[string]*MovieCredits
}

// creditsCacheLimit 限制缓存条目数，避免大库刮削时内存无限增长。
const creditsCacheLimit = 500

func NewPersonScraper(st *store.Store, images *media.ImageStore, client *Client, maxBackdrops int) *PersonScraper {
	remote, _ := newPersonSourceClient("图片", "", "", 2)
	return &PersonScraper{
		store:        st,
		images:       images,
		client:       client,
		maxBackdrops: maxBackdrops,
		logf:         func(string, ...any) {},
		remote:       remote,
		creditsCache: make(map[string]*MovieCredits, 64),
	}
}

// AddSource 注册一个档案来源；重复注册同名来源时以最后一次为准。
func (s *PersonScraper) AddSource(source PersonSource) {
	if source == nil {
		return
	}
	for index, existing := range s.sources {
		if existing.Name() == source.Name() {
			s.sources[index] = source
			sortPersonSources(s.sources)
			return
		}
	}
	s.sources = append(s.sources, source)
	sortPersonSources(s.sources)
}

// SetSourceProxy 让外部图片下载也走代理：AV 站点的图床通常和主站一起被墙。
func (s *PersonScraper) SetSourceProxy(proxy string) {
	client, err := newPersonSourceClient("图片", proxy, "", 2)
	if err != nil {
		s.logf("外部图片代理配置无效: %v", err)
		return
	}
	s.remote = client
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

// Scrape 处理一位演员：先按优先级查各来源并做字段级合并，再写资料与图片。
//
// 顺序很关键：AV 档案站（MinnanoAV > JavDatabase > JavModel > JavDB）命中时不再查 TMDB。
// 女优在 TMDB 上经常被同名的其他演员占用，命中错误的身份比没有资料更糟。
func (s *PersonScraper) Scrape(ctx context.Context, target store.PersonScrapeTarget, force bool) (ScrapeOutcome, error) {
	outcome := ScrapeOutcome{}
	profiles, state := s.lookupSources(ctx, target)
	if err := ctx.Err(); err != nil {
		// 任务被取消时不要拿着半份结果写库。
		return outcome, err
	}

	var (
		tmdbID     string
		tmdbPerson *Person
	)
	if len(profiles) == 0 && s.client != nil && s.client.Configured() {
		tmdbState := ""
		tmdbID, tmdbState = s.resolveTmdbID(ctx, target)
		if tmdbID == "" {
			if state == store.PersonMatchNotFound {
				state = tmdbState
			}
		} else {
			person, err := s.client.Person(ctx, tmdbID)
			if err != nil {
				return outcome, fmt.Errorf("读取演员 %s 失败: %w", target.Name, err)
			}
			tmdbPerson = person
			profiles = append(profiles, s.tmdbProfile(ctx, tmdbID, person))
		}
	}

	merged := mergePersonProfiles(profiles)
	if merged == nil {
		if state == "" {
			state = store.PersonMatchNotFound
		}
		outcome.State = state
		if err := s.store.MarkPersonMatchState(ctx, target.ID, state); err != nil {
			return outcome, err
		}
		return outcome, nil
	}

	updated, err := s.store.ApplyScrapedPerson(ctx, target.ID, store.ScrapedPersonData{
		Overview:     merged.Overview,
		BirthDate:    merged.BirthDate,
		PremiereDate: merged.DebutDate,
		Gender:       merged.Gender,
		CupSize:      merged.CupSize,
		BodyHeight:   merged.BodyHeight,
		Measurements: merged.Measurements,
		Aliases:      filterAliases(target.Name, merged.Aliases),
		ProviderIDs:  merged.ProviderIDs,
	}, force)
	if err != nil {
		return outcome, err
	}
	outcome.State = store.PersonMatchMatched
	outcome.Updated = updated

	images, err := s.applyImages(ctx, target.ID, merged.ImageURL, tmdbID, tmdbPerson, force)
	if err != nil {
		// 图片失败不回滚文字资料，记录后继续跑下一个人。
		s.logf("刮削图片失败 %s: %v", target.Name, err)
	}
	outcome.Images = images
	return outcome, nil
}

// lookupSources 依次查询各来源，返回按优先级排列的档案与汇总状态。
// 单个来源失败只记日志：多源的意义就是任何一个站挂了还有别的兜底。
func (s *PersonScraper) lookupSources(ctx context.Context, target store.PersonScrapeTarget) ([]*PersonProfile, string) {
	query := personQueryFromTarget(target)
	profiles := make([]*PersonProfile, 0, len(s.sources))
	state := store.PersonMatchNotFound

	for _, source := range s.sources {
		if ctx.Err() != nil {
			return profiles, state
		}
		lookup, err := source.Lookup(ctx, query)
		if err != nil {
			s.logf("来源 %s 查询 %s 失败: %v", source.Name(), target.Name, err)
			continue
		}
		switch lookup.State {
		case store.PersonMatchMatched:
			if lookup.Profile != nil {
				profiles = append(profiles, lookup.Profile)
				s.logf("来源 %s 命中 %s（%v）", source.Name(), target.Name, lookup.Profile.ProviderIDs)
			}
		case store.PersonMatchAmbiguous:
			if state == store.PersonMatchNotFound {
				state = store.PersonMatchAmbiguous
			}
			if lookup.Reason != "" {
				s.logf("来源 %s 待确认 %s: %s", source.Name(), target.Name, lookup.Reason)
			}
		}
	}
	return profiles, state
}

// filterAliases 去掉和本地名字完全相同的别名，避免每次刮削都把名字再写进别名列表；
// 不同语言/写法的名字（三上悠亜 / 三上悠亚）会保留，这正是跨站点搜索需要的。
func filterAliases(localName string, aliases []string) []string {
	key := normalizePersonName(localName)
	result := make([]string, 0, len(aliases))
	for _, alias := range aliases {
		if normalizePersonName(alias) == key {
			continue
		}
		result = append(result, alias)
	}
	return result
}

// tmdbProfile 把 TMDB 人物转成统一档案，方便和其他来源做字段级合并。
func (s *PersonScraper) tmdbProfile(ctx context.Context, tmdbID string, person *Person) *PersonProfile {
	providerIDs := map[string]string{"Tmdb": tmdbID}
	// external_ids 失败不影响主流程，只是少了 IMDb 编号。
	if ids, err := s.client.PersonExternalIDs(ctx, tmdbID); err == nil && ids.IMDBID != "" {
		providerIDs["Imdb"] = ids.IMDBID
	}
	return &PersonProfile{
		Source:      "TMDB",
		Name:        person.Name,
		Aliases:     person.AlsoKnownAs,
		BirthDate:   normalizeDate(person.Birthday),
		Gender:      genderLabel(person.Gender),
		Overview:    strings.TrimSpace(person.Biography),
		ProviderIDs: providerIDs,
	}
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
// profileURL 是档案站给出的头像地址（可为空），tmdbID/tmdbPerson 用于 TMDB 头像与写真。
func (s *PersonScraper) applyImages(ctx context.Context, personID, profileURL, tmdbID string, person *Person, force bool) (int, error) {
	locked, err := s.store.ImageLocked(ctx, personID)
	if err != nil {
		return 0, err
	}
	if locked {
		return 0, nil
	}

	saved := 0
	wrotePrimary := false
	// 头像优先级：档案站头像 > TMDB profile。档案站的头像通常是女优本人写真，
	// 比 TMDB 上偶尔张冠李戴的图更可信。
	if profileURL != "" && s.shouldReplaceImage(personID, "Primary", 0, force) {
		if tag, err := s.saveRemoteImage(ctx, personID, profileURL); err == nil {
			if tagErr := s.store.SetPersonImageTag(ctx, personID, "Primary", 0, tag); tagErr == nil {
				saved++
				wrotePrimary = true
			}
		} else {
			s.logf("下载档案站头像失败 %s: %v", personID, err)
		}
	}

	if !wrotePrimary && person != nil && person.ProfilePath != "" && s.shouldReplaceImage(personID, "Primary", 0, force) {
		if tag, err := s.saveImage(ctx, personID, "Primary", 0, person.ProfilePath); err == nil {
			if tagErr := s.store.SetPersonImageTag(ctx, personID, "Primary", 0, tag); tagErr == nil {
				saved++
			}
		}
	}

	if person == nil || s.maxBackdrops <= 0 {
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

// saveRemoteImage 下载外部来源（档案站）的图片并落盘。
func (s *PersonScraper) saveRemoteImage(ctx context.Context, personID, rawURL string) (string, error) {
	client := s.remote
	if client == nil {
		created, err := newPersonSourceClient("图片", "", "", 2)
		if err != nil {
			return "", err
		}
		client = created
	}
	raw, err := client.download(ctx, rawURL)
	if err != nil {
		return "", err
	}
	tag, err := s.images.SaveItemImage(personID, "Primary", 0, raw)
	if err != nil {
		return "", err
	}
	_ = s.images.WriteOrigin(personID, "Primary", 0, media.OriginAuto)
	return tag, nil
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
