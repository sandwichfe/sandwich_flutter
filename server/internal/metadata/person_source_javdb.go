package metadata

import (
	"context"
	"net/url"
	"regexp"
	"strings"

	"embyx/internal/store"
)

const javDBDefaultBaseURL = "https://javdb.com"

// JavDBSource 只负责取女优详情页链接，供前端跳转；
// 档案字段一律不从这里抓（JavDB 的字段不全且为二手数据）。
type JavDBSource struct {
	baseURL string
	client  *personSourceClient
}

func NewJavDBSource(baseURL, proxy, userAgent string, perSecond int) (*JavDBSource, error) {
	client, err := newPersonSourceClient("JavDB", proxy, userAgent, perSecond)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(baseURL) == "" {
		baseURL = javDBDefaultBaseURL
	}
	return &JavDBSource{baseURL: strings.TrimRight(baseURL, "/"), client: client}, nil
}

func (s *JavDBSource) Name() string { return "Javdb" }

func (s *JavDBSource) Priority() int { return personSourcePriorityJavDB }

// SetBaseURL 供测试指向本地假站点。
func (s *JavDBSource) SetBaseURL(baseURL string) {
	if value := strings.TrimRight(strings.TrimSpace(baseURL), "/"); value != "" {
		s.baseURL = value
	}
}

var javDBActorLinkPattern = regexp.MustCompile(`(?i)/actors?/[a-z0-9_-]+`)

func (s *JavDBSource) Lookup(ctx context.Context, query PersonQuery) (PersonLookup, error) {
	keys := personNameKeys(query.Names...)
	var lastErr error
	searched := false

	for _, name := range query.Names {
		if ctx.Err() != nil {
			return PersonLookup{}, ctx.Err()
		}
		searchURL := s.baseURL + "/search?q=" + url.QueryEscape(name) + "&f=actor"
		page, err := s.client.get(ctx, searchURL)
		if err != nil {
			lastErr = err
			continue
		}
		searched = true
		candidates := extractAnchors(page, searchURL, javDBActorLinkPattern)
		if len(candidates) == 0 {
			continue
		}
		candidate, ok := pickCandidate(keys, candidates)
		if !ok {
			continue
		}
		return PersonLookup{
			State: store.PersonMatchMatched,
			Profile: &PersonProfile{
				Source:      s.Name(),
				Name:        candidate.Name,
				Gender:      "Female",
				ProviderIDs: map[string]string{"Javdb": candidate.URL},
			},
		}, nil
	}

	if !searched && lastErr != nil {
		return PersonLookup{}, lastErr
	}
	if searched && lastErr == nil {
		return PersonLookup{State: store.PersonMatchAmbiguous, Reason: "搜索结果无法唯一确定"}, nil
	}
	return PersonLookup{State: store.PersonMatchNotFound}, nil
}
