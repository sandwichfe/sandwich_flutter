package metadata

import (
	"context"
	"net/url"
	"regexp"
	"strings"

	"embyx/internal/store"
)

// minnanoAVDefaultBaseURL 是 みんなのAV 的站点地址，可以在测试里换成假服务。
const minnanoAVDefaultBaseURL = "https://www.minnano-av.com"

// MinnanoAVSource 是女优档案主来源：按日文名搜索，
// 抓日文名/别名、生日、身高、三围、罩杯、出道日与详情页链接。
type MinnanoAVSource struct {
	baseURL string
	client  *personSourceClient
}

func NewMinnanoAVSource(baseURL, proxy, userAgent string, perSecond int) (*MinnanoAVSource, error) {
	client, err := newPersonSourceClient("MinnanoAV", proxy, userAgent, perSecond)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(baseURL) == "" {
		baseURL = minnanoAVDefaultBaseURL
	}
	return &MinnanoAVSource{baseURL: strings.TrimRight(baseURL, "/"), client: client}, nil
}

func (s *MinnanoAVSource) Name() string { return "MinnanoAV" }

func (s *MinnanoAVSource) Priority() int { return personSourcePriorityMinnanoAV }

// SetBaseURL 供测试指向本地假站点。
func (s *MinnanoAVSource) SetBaseURL(baseURL string) {
	if value := strings.TrimRight(strings.TrimSpace(baseURL), "/"); value != "" {
		s.baseURL = value
	}
}

var (
	minnanoActressLinkPattern = regexp.MustCompile(`(?i)/?actress\d+\.html`)
	minnanoActressIDPattern   = regexp.MustCompile(`(?i)actress(\d+)\.html`)
)

func (s *MinnanoAVSource) Lookup(ctx context.Context, query PersonQuery) (PersonLookup, error) {
	keys := personNameKeys(query.Names...)
	var lastErr error
	searched := false

	for _, name := range query.Names {
		if ctx.Err() != nil {
			return PersonLookup{}, ctx.Err()
		}
		searchURL := s.baseURL + "/search_result.php?search_scope=actress&search_word=" +
			url.QueryEscape(name) + "&search=" + url.QueryEscape("検索")
		page, err := s.client.get(ctx, searchURL)
		if err != nil {
			lastErr = err
			continue
		}
		searched = true
		candidates := extractAnchors(page, searchURL, minnanoActressLinkPattern)
		if len(candidates) == 0 {
			continue
		}
		candidate, ok := pickCandidate(keys, candidates)
		if !ok {
			continue
		}
		profile, err := s.fetchProfile(ctx, candidate)
		if err != nil {
			lastErr = err
			continue
		}
		return PersonLookup{State: store.PersonMatchMatched, Profile: profile}, nil
	}

	if !searched && lastErr != nil {
		return PersonLookup{}, lastErr
	}
	if searched && lastErr == nil {
		return PersonLookup{State: store.PersonMatchAmbiguous, Reason: "搜索结果无法唯一确定"}, nil
	}
	return PersonLookup{State: store.PersonMatchNotFound}, nil
}

func (s *MinnanoAVSource) fetchProfile(ctx context.Context, candidate PersonCandidate) (*PersonProfile, error) {
	page, err := s.client.get(ctx, candidate.URL)
	if err != nil {
		return nil, err
	}
	values := htmlLabelValues(page)
	name := htmlHeading(page)
	if name == "" {
		name = candidate.Name
	}
	name = cleanPersonDisplayName(name)

	imageURL := htmlMetaContent(page, "og:image")
	if imageURL == "" {
		imageURL = firstImageWithHint(page, "actress", "/prof", "/photo")
	}
	imageURL = absoluteURL(candidate.URL, imageURL)

	providerIDs := map[string]string{"MinnanoAV": candidate.URL}
	if match := minnanoActressIDPattern.FindStringSubmatch(candidate.URL); len(match) >= 2 {
		providerIDs["MinnanoAV"] = match[1]
	}

	return &PersonProfile{
		Source:       s.Name(),
		Name:         name,
		Aliases:      splitAliases(labelValue(values, "別名", "旧名", "別名義", "ローマ字", "英文名")),
		BirthDate:    normalizeDate(labelValue(values, "生年月日", "誕生日", "生日")),
		DebutDate:    normalizeDate(labelValue(values, "デビュー", "デビュー日", "出道日", "出道")),
		Gender:       "Female",
		CupSize:      normalizeCup(labelValue(values, "カップ", "罩杯")),
		BodyHeight:   normalizeHeight(labelValue(values, "身長", "身高")),
		Measurements: normalizeMeasurements(labelValue(values, "スリーサイズ", "三围", "サイズ")),
		Overview:     strings.TrimSpace(labelValue(values, "紹介", "プロフィール", "簡介")),
		ImageURL:     imageURL,
		ProviderIDs:  providerIDs,
	}, nil
}
