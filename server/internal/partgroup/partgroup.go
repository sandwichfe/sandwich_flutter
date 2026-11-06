// Package partgroup 解析「分片影片」的文件名后缀并派生分组键。
//
// 规则刻意保守：只有带明确序号的后缀才参与分组（`_1`、`-cd2`、`part3`、
// `(2)`、`上/下` 等），分辨率、编码这类后缀一律不识别。宁可漏关联，
// 也不能把两部不同的影片串成一组。
package partgroup

import (
	"path/filepath"
	"regexp"
	"strings"
)

// Part 是从文件名后缀解析出的分片信息。
type Part struct {
	// Stem 是去掉分片后缀后的原始标题，保留原有大小写。
	Stem string
	// Index 是文件名里写的原始序号，从 1 起。
	Index int
}

// 后缀的几种写法。三条规则互斥，按「关键字 → 括号 → 裸序号」的顺序尝试，
// 避免 `-cd2` 被裸序号规则先截成 `-cd`。
var (
	keywordSuffix = regexp.MustCompile(`(?i)^(.*?)[\s._-]+(?:cd|dvd|disc|part|pt)[\s._-]?(\d{1,2})$`)
	bracketSuffix = regexp.MustCompile(`^(.*?)\s*[\(\[（【]\s*(\d{1,2})\s*[\)\]）】]$`)
	bareSuffix    = regexp.MustCompile(`^(.*?)[\s._-]+(\d{1,2})$`)
	dotRuns       = regexp.MustCompile(`[._]+`)
)

// 中文分片后缀：这些写法不带数字，但语义上明确是同一部片的上/下两段。
var chineseSuffixes = []struct {
	suffix string
	index  int
}{
	{"前篇", 1}, {"后篇", 2},
	{"上集", 1}, {"下集", 2},
	{"上部", 1}, {"下部", 2},
	{"上", 1}, {"下", 2},
}

// ParseSuffix 解析去掉扩展名后的文件名，判断它是不是分片。
// 返回的 ok 为 false 表示不是分片，调用方不应参与分组。
func ParseSuffix(base string) (Part, bool) {
	name := strings.TrimSpace(base)
	if name == "" {
		return Part{}, false
	}

	for _, entry := range chineseSuffixes {
		if !strings.HasSuffix(name, entry.suffix) {
			continue
		}
		stem := trimDecorations(strings.TrimSuffix(name, entry.suffix))
		if stem == "" {
			continue
		}
		return Part{Stem: stem, Index: entry.index}, true
	}

	if part, ok := matchSuffix(keywordSuffix, name); ok {
		return part, true
	}
	if part, ok := matchSuffix(bracketSuffix, name); ok {
		return part, true
	}
	return matchSuffix(bareSuffix, name)
}

func matchSuffix(pattern *regexp.Regexp, name string) (Part, bool) {
	match := pattern.FindStringSubmatch(name)
	if match == nil {
		return Part{}, false
	}
	index := 0
	for _, char := range match[2] {
		index = index*10 + int(char-'0')
	}
	if index < 1 || index > 99 {
		return Part{}, false
	}
	stem := trimDecorations(match[1])
	if stem == "" {
		// 纯数字的文件名（例如 `1.mp4`）没有标题可做分组依据。
		return Part{}, false
	}
	return Part{Stem: stem, Index: index}, true
}

// trimDecorations 去掉标题两端的连接符与装饰括号，`Movie -` 与 `Movie` 视为同一标题。
func trimDecorations(value string) string {
	return strings.Trim(value, " \t._-[](){}【】（）")
}

// NormalizeStem 把标题归一化成分组用的键片段：小写、分隔符统一成空格、去两端装饰字符。
// 与扫描时的 cleanTitle 语义一致，但这里只做字符串级归一化，不做模糊匹配。
func NormalizeStem(stem string) string {
	normalized := strings.ToLower(strings.TrimSpace(stem))
	normalized = dotRuns.ReplaceAllString(normalized, " ")
	normalized = strings.Join(strings.Fields(normalized), " ")
	return strings.Trim(normalized, " .-_[](){}【】（）")
}

// GroupKey 拼出分组键：媒体库 + 相对目录 + 归一化标题。
//
// 必须带上媒体库与相对目录，否则两个库里同名的 `3070118_1` 会串成一组，
// 同一库里不同目录的同名文件同理。用相对目录而不是绝对路径，
// 是为了整个库换盘符、换挂载点后分组关系仍然成立。
func GroupKey(libraryID, relDir, stem string) string {
	normalized := NormalizeStem(stem)
	if normalized == "" || libraryID == "" {
		return ""
	}
	dir := strings.ToLower(filepath.ToSlash(relDir))
	if dir == "." {
		dir = ""
	}
	dir = strings.Trim(dir, "/")
	return libraryID + "|" + dir + "|" + normalized
}
