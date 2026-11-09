package metadata

import (
	"context"
	"net/url"
	"regexp"
	"strings"

	"embyx/internal/store"
)

const javDatabaseDefaultBaseURL = "https://www.javdatabase.com"

// JavDatabaseSource 是兜底来源：档案字段比 MinnanoAV 略少，
// 主要补身高/三围/罩杯/生日以及英文名。
type JavDatabaseSource struct {
	baseURL string
	client  *personSourceClient
}

func NewJavDatabaseSource(baseURL, proxy, userAgent string, perSecond int) (*JavDatabaseSource, error) {
	client, err := newPersonSourceClient("JavDatabase", proxy, userAgent, perSecond)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(baseURL) == "" {
		baseURL = javDatabaseDefaultBaseURL
	}
	return &JavDatabaseSource{baseURL: strings.TrimRight(baseURL, "/"), client: client}, nil
}

func (s *JavDatabaseSource) Name() string { return "Javdatabase" }

func (s *JavDatabaseSource) Priority() int { return personSourcePriorityJavDatabase }

// SetBaseURL 供测试指向本地假站点。
func (s *JavDatabaseSource) SetBaseURL(baseURL string) {
	if value := strings.TrimRight(strings.TrimSpace(baseURL), "/"); value != "" {
		s.baseURL = value
	}
}

var javDatabaseIdolLinkPattern = regexp.MustCompile(`(?i)/idols/[a-z0-9._-]+/?`)

func (s *JavDatabaseSource) Lookup(ctx context.Context, query PersonQuery) (PersonLookup, error) {
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
		candidates := extractAnchors(page, searchURL, javDatabaseIdolLinkPattern)
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

func (s *JavDatabaseSource) fetchProfile(ctx context.Context, candidate PersonCandidate) (*PersonProfile, error) {
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
		imageURL = absoluteURL(candidate.URL, firstImageWithHint(page, "idol", "profile", "/upload"))
	}

	return &PersonProfile{
		Source:       s.Name(),
		Name:         name,
		Aliases:      splitAliases(labelValue(values, "Aliases", "Also Known As", "別名", "旧名")),
		BirthDate:    normalizeDate(labelValue(values, "Birthdate", "Birthday", "Date of Birth", "生年月日")),
		DebutDate:    normalizeDate(labelValue(values, "Debut", "Debut Date", "デビュー")),
		Gender:       "Female",
		CupSize:      normalizeCup(labelValue(values, "Cup Size", "Cup", "カップ")),
		BodyHeight:   normalizeHeight(labelValue(values, "Height", "身長")),
		Measurements: normalizeMeasurements(labelValue(values, "Measurements", "Measurements (B/W/H)", "B/W/H", "スリーサイズ")),
		Overview:     strings.TrimSpace(labelValue(values, "Description", "About", "Biography", "紹介")),
		ImageURL:     imageURL,
		ProviderIDs:  map[string]string{"Javdatabase": idolSlug(candidate.URL)},
	}, nil
}

// idolSlug 从 /idols/<slug>/ 里取编号，供前端拼详情页链接与后续定位。
func idolSlug(rawURL string) string {
	trimmed := strings.TrimRight(rawURL, "/")
	if index := strings.LastIndex(trimmed, "/"); index >= 0 {
		return trimmed[index+1:]
	}
	return trimmed
}
