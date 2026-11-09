package metadata

import (
	"context"
	"net/url"
	"regexp"
	"strings"

	"embyx/internal/store"
)

const javModelDefaultBaseURL = "https://javmodel.com"

// JavModelSource 是第三优先级来源，字段最少但页面结构简单，
// 常用于补身高、三围与罩杯。
type JavModelSource struct {
	baseURL string
	client  *personSourceClient
}

func NewJavModelSource(baseURL, proxy, userAgent string, perSecond int) (*JavModelSource, error) {
	client, err := newPersonSourceClient("JavModel", proxy, userAgent, perSecond)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(baseURL) == "" {
		baseURL = javModelDefaultBaseURL
	}
	return &JavModelSource{baseURL: strings.TrimRight(baseURL, "/"), client: client}, nil
}

func (s *JavModelSource) Name() string { return "Javmodel" }

func (s *JavModelSource) Priority() int { return personSourcePriorityJavModel }

// SetBaseURL 供测试指向本地假站点。
func (s *JavModelSource) SetBaseURL(baseURL string) {
	if value := strings.TrimRight(strings.TrimSpace(baseURL), "/"); value != "" {
		s.baseURL = value
	}
}

var javModelIdolLinkPattern = regexp.MustCompile(`(?i)/jav/[a-z0-9._-]+/?`)

func (s *JavModelSource) Lookup(ctx context.Context, query PersonQuery) (PersonLookup, error) {
	keys := personNameKeys(query.Names...)
	var lastErr error
	searched := false

	for _, name := range query.Names {
		if ctx.Err() != nil {
			return PersonLookup{}, ctx.Err()
		}
		searchURL := s.baseURL + "/?s=" + url.QueryEscape(name)
		page, err := s.client.get(ctx, searchURL)
		if err != nil {
			lastErr = err
			continue
		}
		searched = true
		candidates := extractAnchors(page, searchURL, javModelIdolLinkPattern)
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

func (s *JavModelSource) fetchProfile(ctx context.Context, candidate PersonCandidate) (*PersonProfile, error) {
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

	imageURL := absoluteURL(candidate.URL, htmlMetaContent(page, "og:image"))
	if imageURL == "" {
		imageURL = absoluteURL(candidate.URL, firstImageWithHint(page, "model", "actress", "/upload"))
	}

	return &PersonProfile{
		Source:       s.Name(),
		Name:         name,
		Aliases:      splitAliases(labelValue(values, "Aliases", "Also Known As", "別名", "旧名")),
		BirthDate:    normalizeDate(labelValue(values, "Birthday", "Birthdate", "Date of Birth", "生年月日")),
		DebutDate:    normalizeDate(labelValue(values, "Debut", "Debut Date", "デビュー")),
		Gender:       "Female",
		CupSize:      normalizeCup(labelValue(values, "Cup Size", "Cup", "カップ")),
		BodyHeight:   normalizeHeight(labelValue(values, "Height", "身長")),
		Measurements: normalizeMeasurements(labelValue(values, "Measurements", "B/W/H", "スリーサイズ", "三围")),
		Overview:     strings.TrimSpace(labelValue(values, "Description", "About", "紹介")),
		ImageURL:     imageURL,
		ProviderIDs:  map[string]string{"Javmodel": idolSlug(candidate.URL)},
	}, nil
}
