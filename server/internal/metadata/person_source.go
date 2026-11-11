package metadata

import (
	"context"
	"regexp"
	"sort"
	"strings"

	"embyx/internal/store"
)

// 来源优先级：数值越大越靠前，合并时逐字段取第一个非空值。
// 顺序按「档案完整度」排：MinnanoAV 有日文名/身高/三围/罩杯/出道日，
// JavDatabase 与 JavModel 作为兜底，JavDB 只提供详情页链接，TMDB 最后兜底。
const (
	personSourcePriorityMinnanoAV   = 40
	personSourcePriorityJavDatabase = 30
	personSourcePriorityJavModel    = 20
	personSourcePriorityJavDB       = 10
	personSourcePriorityTMDB        = 0
)

// PersonQuery 是一次演员搜索的输入。
type PersonQuery struct {
	// Names 是依次尝试的名字：本地名 + 已记录别名（日文名/罗马名/中文名）。
	Names []string
	// Works 是关联作品名，用于番号交叉验证（可选）。
	Works []string
}

// PersonCandidate 是搜索结果里的一个候选。
type PersonCandidate struct {
	Name string
	URL  string
}

// PersonProfile 是某个来源给出的演员档案，空字符串表示该来源没有这个字段。
type PersonProfile struct {
	Source       string
	Name         string
	Aliases      []string
	BirthDate    string
	DebutDate    string
	Gender       string
	CupSize      string
	BodyHeight   string
	Measurements string
	Overview     string
	ImageURL     string
	ProviderIDs  map[string]string
}

// PersonLookup 是单个来源的查询结果。
type PersonLookup struct {
	// State 取值 matched / ambiguous / not_found。
	State   string
	Profile *PersonProfile
	// Reason 只用于日志，说明没匹配上的原因。
	Reason string
}

// PersonSource 是演员档案来源。实现方自己负责搜索 + 详情页解析，
// 合并优先级与写库由 PersonScraper 统一处理。
type PersonSource interface {
	// Name 是来源名，同时作为 ProviderIDs 的键（例如 MinnanoAV）。
	Name() string
	// Priority 越大越优先。
	Priority() int
	Lookup(ctx context.Context, query PersonQuery) (PersonLookup, error)
}

// personSourceAVProviders 是 AV 档案站在 ProviderIDs 里使用的键。
var personSourceAVProviders = []string{"MinnanoAV", "Javdatabase", "Javmodel", "Javdb"}

// javWorkCodePattern 匹配作品番号（SSIS-123 / ABP123），用于判断演员是否属于 AV 库。
var javWorkCodePattern = regexp.MustCompile(`[A-Z]{2,6}[-_ ]?\d{2,5}`)

// personQueryFromTarget 把刮削目标转成统一查询：本地名在前，别名去重后跟随后面。
func personQueryFromTarget(target store.PersonScrapeTarget) PersonQuery {
	names := make([]string, 0, len(target.Aliases)+1)
	seen := make(map[string]bool, len(target.Aliases)+1)
	appendName := func(value string) {
		key := normalizePersonName(value)
		if key == "" || seen[key] {
			return
		}
		seen[key] = true
		names = append(names, strings.TrimSpace(value))
	}
	appendName(target.Name)
	for _, alias := range target.Aliases {
		appendName(alias)
	}
	return PersonQuery{Names: names, Works: append([]string(nil), target.MovieNames...)}
}

// personNameKeys 归一化所有已知名字，供候选打分。
func personNameKeys(names ...string) map[string]bool {
	keys := make(map[string]bool, len(names))
	for _, name := range names {
		if key := normalizePersonName(name); key != "" {
			keys[key] = true
		}
	}
	return keys
}

// looksLikeJavTarget 判断这位演员是否更像 AV 女优：
// 已有 AV 来源编号，或关联作品里出现番号。
func looksLikeJavTarget(target store.PersonScrapeTarget) bool {
	for _, provider := range personSourceAVProviders {
		if strings.TrimSpace(target.ProviderIDs[provider]) != "" {
			return true
		}
	}
	for _, name := range target.MovieNames {
		if javWorkCodePattern.MatchString(name) {
			return true
		}
	}
	return false
}

// mergePersonProfiles 按传入顺序（优先级从高到低）逐字段合并。
// ProviderIDs 按键取「先出现」的值，多个来源的编号会同时保留。
func mergePersonProfiles(profiles []*PersonProfile) *PersonProfile {
	result := &PersonProfile{ProviderIDs: make(map[string]string)}
	aliases := make([]string, 0, 8)
	aliasSeen := make(map[string]bool, 8)
	addAlias := func(value string) {
		key := normalizePersonName(value)
		if key == "" || aliasSeen[key] {
			return
		}
		aliasSeen[key] = true
		aliases = append(aliases, strings.TrimSpace(value))
	}
	fill := func(dst *string, value string) {
		if *dst == "" && strings.TrimSpace(value) != "" {
			*dst = strings.TrimSpace(value)
		}
	}

	matched := false
	for _, profile := range profiles {
		if profile == nil {
			continue
		}
		matched = true
		fill(&result.Name, profile.Name)
		fill(&result.BirthDate, profile.BirthDate)
		fill(&result.DebutDate, profile.DebutDate)
		fill(&result.Gender, profile.Gender)
		fill(&result.CupSize, profile.CupSize)
		fill(&result.BodyHeight, profile.BodyHeight)
		fill(&result.Measurements, profile.Measurements)
		fill(&result.Overview, profile.Overview)
		fill(&result.ImageURL, profile.ImageURL)
		addAlias(profile.Name)
		for _, alias := range profile.Aliases {
			addAlias(alias)
		}
		for key, value := range profile.ProviderIDs {
			if value == "" {
				continue
			}
			if _, exists := result.ProviderIDs[key]; !exists {
				result.ProviderIDs[key] = value
			}
		}
	}
	if !matched {
		return nil
	}
	result.Aliases = aliases
	return result
}

// scoreCandidate 按「完全同名 100 分 / 互相包含 40 分」给候选打分。
// 只靠包含关系不足以采信，调用方会把 0 < 分数 < 100 视为待确认。
func scoreCandidate(keys map[string]bool, candidate PersonCandidate) int {
	if len(keys) == 0 {
		return 0
	}
	best := 0
	for _, name := range append([]string{candidate.Name}, candidateAliases(candidate)...) {
		key := normalizePersonName(name)
		if key == "" {
			continue
		}
		if keys[key] {
			return 100
		}
		for known := range keys {
			if len(known) < 2 || len(key) < 2 {
				continue
			}
			if strings.Contains(key, known) || strings.Contains(known, key) {
				if best < 40 {
					best = 40
				}
			}
		}
	}
	return best
}

// candidateAliases 目前搜索结果里只带名字，单独抽出来是为了将来支持带别名的候选。
func candidateAliases(PersonCandidate) []string { return nil }

// pickCandidate 在候选列表里挑唯一最优解。
// 分数不到 100 或出现并列时返回 false，让调用方标记为待确认而不是认错人。
func pickCandidate(keys map[string]bool, candidates []PersonCandidate) (PersonCandidate, bool) {
	best := PersonCandidate{}
	bestScore := 0
	tie := false
	for _, candidate := range candidates {
		score := scoreCandidate(keys, candidate)
		if score <= 0 {
			continue
		}
		switch {
		case score > bestScore:
			best, bestScore, tie = candidate, score, false
		case score == bestScore:
			tie = true
		}
	}
	if bestScore < 100 || tie {
		return PersonCandidate{}, false
	}
	return best, true
}

// sortPersonSources 按优先级从高到低排序，优先级相同时保持注册顺序。
func sortPersonSources(sources []PersonSource) {
	sort.SliceStable(sources, func(i, j int) bool {
		return sources[i].Priority() > sources[j].Priority()
	})
}
