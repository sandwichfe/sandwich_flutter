package media

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// NFOData 是 Kodi/Emby/Jellyfin 通用 NFO 的归一化结果。
// 只做读取，不做任何网络刮削：元数据由外部工具（TMM / Emby / tinyMediaManager）预先生成。
type NFOData struct {
	Type string // movie / tvshow / episodedetails

	Title         string
	OriginalTitle string
	SortTitle     string

	Plot    string
	Outline string
	Tagline string

	RuntimeMinutes int
	Year           int
	Premiered      string
	DateAdded      string

	MPAA   string
	Rating float64
	Votes  int

	Genres    []string
	Tags      []string
	Studios   []string
	Set       string
	Directors []string
	Writers   []string
	Actors    []NFOActor

	UniqueIDs map[string]string

	Season  int
	Episode int
}

type NFOActor struct {
	Name  string
	Role  string
	Order int
}

// FindNFO 按 Kodi 约定查找 NFO：先同名文件，再目录级 movie.nfo。
func FindNFO(videoPath string) string {
	base := strings.TrimSuffix(videoPath, filepath.Ext(videoPath))
	candidates := []string{
		base + ".nfo",
		filepath.Join(filepath.Dir(videoPath), "movie.nfo"),
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return ""
}

func ParseNFO(path string) (*NFOData, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取 NFO 失败: %w", err)
	}
	// Windows 编辑器常写入 UTF-8 BOM，xml.Unmarshal 会因此直接报错。
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})

	var root nfoRoot
	if err := xml.Unmarshal(raw, &root); err != nil {
		// 非 UTF-8 编码的 NFO 会在这里失败，调用方回退到文件名推断。
		return nil, fmt.Errorf("解析 NFO 失败: %w", err)
	}

	data := &NFOData{
		Type:           strings.TrimSpace(root.XMLName.Local),
		Title:          cleanText(root.Title),
		OriginalTitle:  cleanText(root.OriginalTitle),
		SortTitle:      cleanText(root.SortTitle),
		Plot:           cleanText(root.Plot),
		Outline:        cleanText(root.Outline),
		Tagline:        cleanText(root.Tagline),
		RuntimeMinutes: root.Runtime,
		Year:           root.Year,
		Premiered:      cleanText(root.Premiered),
		DateAdded:      cleanText(root.DateAdded),
		MPAA:           cleanText(root.MPAA),
		Rating:         root.Rating,
		Genres:         cleanList(root.Genres),
		Tags:           cleanList(root.Tags),
		Studios:        cleanList(root.Studios),
		Directors:      cleanList(root.Directors),
		Writers:        cleanList(root.Credits),
		UniqueIDs:      map[string]string{},
		Season:         root.Season,
		Episode:        root.Episode,
	}
	if root.Set.Name != "" {
		data.Set = cleanText(root.Set.Name)
	}

	// 新格式用 <ratings>，旧格式用顶层 <rating>。
	if rating := pickRating(root.Ratings); rating != nil {
		data.Rating = rating.Value
		data.Votes = rating.Votes
	}

	for _, uniqueID := range root.UniqueIDs {
		kind := cleanText(uniqueID.Type)
		value := cleanText(uniqueID.Value)
		if kind == "" || value == "" {
			continue
		}
		data.UniqueIDs[kind] = value
	}
	// 无 uniqueid 时旧的 <id> 可能直接是 TMDB 编号。
	if len(data.UniqueIDs) == 0 && cleanText(root.ID) != "" {
		data.UniqueIDs["tmdb"] = cleanText(root.ID)
	}

	for _, actor := range root.Actors {
		name := cleanText(actor.Name)
		if name == "" {
			continue
		}
		data.Actors = append(data.Actors, NFOActor{
			Name:  name,
			Role:  cleanText(actor.Role),
			Order: actor.Order,
		})
	}

	return data, nil
}

// NormalizedPremiereDate 把 NFO 的日期统一成客户端可解析的 UTC ISO8601。
func (n *NFOData) NormalizedPremiereDate() string {
	return normalizeNFODate(n.Premiered)
}

func (n *NFOData) NormalizedDateAdded() string {
	return normalizeNFODate(n.DateAdded)
}

func normalizeNFODate(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	layouts := []string{
		"2006-01-02 15:04:05",
		"2006-01-02",
		time.RFC3339,
	}
	for _, layout := range layouts {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed.UTC().Format("2006-01-02T15:04:05.0000000Z")
		}
	}
	return value
}

// ---------- XML 映射 ----------

// XMLName 不限定根元素名，同一次解析即可兼容 movie / tvshow / episodedetails。
type nfoRoot struct {
	XMLName xml.Name

	Title         string `xml:"title"`
	OriginalTitle string `xml:"originaltitle"`
	SortTitle     string `xml:"sorttitle"`

	Plot    string `xml:"plot"`
	Outline string `xml:"outline"`
	Tagline string `xml:"tagline"`

	Runtime   int    `xml:"runtime"`
	Year      int    `xml:"year"`
	Premiered string `xml:"premiered"`
	DateAdded string `xml:"dateadded"`

	MPAA   string  `xml:"mpaa"`
	Rating float64 `xml:"rating"`
	ID     string  `xml:"id"`

	Ratings   nfoRatings    `xml:"ratings"`
	UniqueIDs []nfoUniqueID `xml:"uniqueid"`

	Genres    []string   `xml:"genre"`
	Tags      []string   `xml:"tag"`
	Studios   []string   `xml:"studio"`
	Credits   []string   `xml:"credits"`
	Directors []string   `xml:"director"`
	Set       nfoSet     `xml:"set"`
	Actors    []nfoActor `xml:"actor"`

	Season  int `xml:"season"`
	Episode int `xml:"episode"`
}

type nfoSet struct {
	Name string `xml:"name"`
}

type nfoUniqueID struct {
	Type    string `xml:"type,attr"`
	Default bool   `xml:"default,attr"`
	Value   string `xml:",chardata"`
}

type nfoRatings struct {
	Items []nfoRating `xml:"rating"`
}

type nfoRating struct {
	Name    string  `xml:"name,attr"`
	Max     string  `xml:"max,attr"`
	Default string  `xml:"default,attr"`
	Value   float64 `xml:"value"`
	Votes   int     `xml:"votes"`
}

type nfoActor struct {
	Name  string `xml:"name"`
	Role  string `xml:"role"`
	Order int    `xml:"order"`
}

func pickRating(ratings nfoRatings) *nfoRating {
	if len(ratings.Items) == 0 {
		return nil
	}
	for index := range ratings.Items {
		if strings.EqualFold(ratings.Items[index].Default, "true") && ratings.Items[index].Value > 0 {
			return &ratings.Items[index]
		}
	}
	for index := range ratings.Items {
		if strings.EqualFold(ratings.Items[index].Name, "themoviedb") && ratings.Items[index].Value > 0 {
			return &ratings.Items[index]
		}
	}
	for index := range ratings.Items {
		if ratings.Items[index].Value > 0 {
			return &ratings.Items[index]
		}
	}
	return nil
}

func cleanText(value string) string {
	return strings.TrimSpace(value)
}

func cleanList(values []string) []string {
	result := make([]string, 0, len(values))
	seen := map[string]bool{}
	for _, value := range values {
		value = cleanText(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}
