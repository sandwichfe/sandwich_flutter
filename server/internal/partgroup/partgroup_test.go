package partgroup

import "testing"

// TestParseSuffix 覆盖设计里「能识别 / 不识别」两张表的全部写法。
func TestParseSuffix(t *testing.T) {
	cases := []struct {
		base  string
		stem  string
		index int
		ok    bool
	}{
		{"3070118_1", "3070118", 1, true},
		{"3070118_2", "3070118", 2, true},
		{"Movie-cd1", "Movie", 1, true},
		{"Movie part2", "Movie", 2, true},
		{"Movie.pt3", "Movie", 3, true},
		{"Movie disc4", "Movie", 4, true},
		{"Movie dvd5", "Movie", 5, true},
		{"Movie (1)", "Movie", 1, true},
		{"Movie [2]", "Movie", 2, true},
		{"Movie（3）", "Movie", 3, true},
		{"某影片上", "某影片", 1, true},
		{"某影片下", "某影片", 2, true},
		{"某影片后篇", "某影片", 2, true},
		// 不是分片：无序号、分辨率、编码、纯数字名。
		{"Movie.1080p", "", 0, false},
		{"Movie x265", "", 0, false},
		{"Movie 2160p", "", 0, false},
		{"Movie 2023", "", 0, false},
		{"1", "", 0, false},
		// 年份是 4 位数，不会被当成序号。
		{"Some Movie 2019", "", 0, false},
	}

	for _, entry := range cases {
		part, ok := ParseSuffix(entry.base)
		if ok != entry.ok {
			t.Fatalf("%s: ok=%v，期望 %v", entry.base, ok, entry.ok)
		}
		if !ok {
			continue
		}
		if part.Stem != entry.stem || part.Index != entry.index {
			t.Fatalf("%s: 得到 %q/%d，期望 %q/%d",
				entry.base, part.Stem, part.Index, entry.stem, entry.index)
		}
	}
}

// TestGroupKeyIsolatesLibraryAndDirectory 确认分组键带上库与目录：
// 两个库、同一库的两个目录里的同名分片都不能串成一组。
func TestGroupKeyIsolatesLibraryAndDirectory(t *testing.T) {
	part, ok := ParseSuffix("3070118_1")
	if !ok {
		t.Fatal("应识别为分片")
	}
	base := GroupKey("lib1", "A", part.Stem)
	if base == "" {
		t.Fatal("分组键不应为空")
	}
	if base == GroupKey("lib2", "A", part.Stem) {
		t.Fatal("不同媒体库的同名文件不能成组")
	}
	if base == GroupKey("lib1", "B", part.Stem) {
		t.Fatal("同库不同目录的同名文件不能成组")
	}
	// 大小写与分隔符差异归一化后仍是同一组。
	if base != GroupKey("lib1", `a`, part.Stem) {
		t.Fatal("目录大小写应归一到同一组")
	}
	if base != GroupKey("lib1", "A", "3070118") {
		t.Fatal("标题归一化后应得到同一分组键")
	}
}
