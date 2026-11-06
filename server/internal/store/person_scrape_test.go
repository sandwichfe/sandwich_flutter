package store

import (
	"context"
	"testing"

	"embyx/internal/dto"
)

// TestApplyScrapedPersonModes 覆盖刮削写库的三种情形：补空、覆盖、手动锁。
func TestApplyScrapedPersonModes(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	item := movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{actor("p1", "张三")})
	item.ProviderIDs = map[string]string{"Tmdb": "550"}
	if err := st.UpsertItem(ctx, item); err != nil {
		t.Fatal(err)
	}

	// 1. 首次刮削：字段为空，直接写入。
	first := ScrapedPersonData{
		Overview:    "简介A",
		BirthDate:   "1985-06-01",
		Gender:      "Female",
		ProviderIDs: map[string]string{"Tmdb": "999", "Imdb": "nm1"},
	}
	if applied, err := st.ApplyScrapedPerson(ctx, "p1", first, false); err != nil || !applied {
		t.Fatalf("首次刮削应写入: applied=%v err=%v", applied, err)
	}
	person, err := st.PersonByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if person.Overview != "简介A" || person.BirthDate != "1985-06-01" || person.Gender != "Female" {
		t.Fatalf("首次刮削字段不符: %+v", person)
	}
	if person.ProviderIDs["Tmdb"] != "999" || person.ProviderIDs["Imdb"] != "nm1" {
		t.Fatalf("外部编号未写入: %v", person.ProviderIDs)
	}

	// 2. 非 force：已有值不覆盖。
	if applied, err := st.ApplyScrapedPerson(ctx, "p1", ScrapedPersonData{Overview: "简介B", Gender: "Male"}, false); err != nil || applied {
		t.Fatalf("非 force 不应覆盖: applied=%v err=%v", applied, err)
	}
	if person, _ = st.PersonByID(ctx, "p1"); person.Overview != "简介A" || person.Gender != "Female" {
		t.Fatalf("非 force 覆盖了字段: %+v", person)
	}

	// 3. force：覆盖文本字段，但不清掉已有外部编号。
	if _, err := st.ApplyScrapedPerson(ctx, "p1", ScrapedPersonData{Overview: "简介C", ProviderIDs: map[string]string{"Imdb": "nm2"}}, true); err != nil {
		t.Fatal(err)
	}
	person, _ = st.PersonByID(ctx, "p1")
	if person.Overview != "简介C" || person.ProviderIDs["Tmdb"] != "999" || person.ProviderIDs["Imdb"] != "nm2" {
		t.Fatalf("force 覆盖结果不符: %+v / %v", person, person.ProviderIDs)
	}

	// 4. 手动编辑过的字段即使 force 也不能被刮削改掉。
	if err := st.UpdatePersonMetadata(ctx, "p1", map[string]any{"Overview": "人工简介"}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ApplyScrapedPerson(ctx, "p1", ScrapedPersonData{Overview: "简介D", Gender: "Male"}, true); err != nil {
		t.Fatal(err)
	}
	person, _ = st.PersonByID(ctx, "p1")
	if person.Overview != "人工简介" {
		t.Fatalf("手动锁字段被覆盖: %q", person.Overview)
	}
	if person.Gender != "Male" {
		t.Fatalf("未锁字段应被 force 覆盖: %q", person.Gender)
	}
}

// TestPersonScrapeTargets 验证候选集与「按影片反查」需要的 Tmdb 编号。
func TestPersonScrapeTargets(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	item := movieItem("i1", "Alpha", nil, nil, nil, []dto.PersonDto{
		actor("p1", "张三"),
		actor("p2", "李四"),
	})
	item.ProviderIDs = map[string]string{"Tmdb": "550"}
	if err := st.UpsertItem(ctx, item); err != nil {
		t.Fatal(err)
	}

	targets, err := st.PersonScrapeTargets(ctx, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 2 {
		t.Fatalf("候选人数 = %d, 期望 2", len(targets))
	}
	if len(targets[0].MovieTmdb) != 1 || targets[0].MovieTmdb[0] != "550" {
		t.Fatalf("影片 Tmdb 编号未带出: %+v", targets[0].MovieTmdb)
	}
	if len(targets[0].MovieNames) != 1 || targets[0].MovieNames[0] != "Alpha" {
		t.Fatalf("影片名未带出: %+v", targets[0].MovieNames)
	}

	// 张三刮过之后，onlyMissing 只剩下李四。
	if _, err := st.ApplyScrapedPerson(ctx, "p1", ScrapedPersonData{
		ProviderIDs: map[string]string{"Tmdb": "42"},
	}, false); err != nil {
		t.Fatal(err)
	}
	targets, err = st.PersonScrapeTargets(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 1 || targets[0].ID != "p2" {
		t.Fatalf("增量候选不符: %+v", targets)
	}

	// 单人参数读取。
	target, err := st.PersonScrapeTargetByID(ctx, "p2")
	if err != nil || target.Name != "李四" {
		t.Fatalf("单人目标读取失败: %+v err=%v", target, err)
	}
}

// TestMarkPersonMatchState 验证重名/未找到只记录状态，不写资料。
func TestMarkPersonMatchState(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()

	if err := st.UpsertItem(ctx, movieItem("i1", "Alpha", nil, nil, nil,
		[]dto.PersonDto{actor("p1", "张三")})); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkPersonMatchState(ctx, "p1", PersonMatchAmbiguous); err != nil {
		t.Fatal(err)
	}
	target, err := st.PersonScrapeTargetByID(ctx, "p1")
	if err != nil {
		t.Fatal(err)
	}
	if target.MatchState != PersonMatchAmbiguous || target.ScrapedAt == "" {
		t.Fatalf("状态未记录: %+v", target)
	}
	if len(target.ProviderIDs) != 0 {
		t.Fatalf("不确定的匹配不应写外部编号: %v", target.ProviderIDs)
	}
}
