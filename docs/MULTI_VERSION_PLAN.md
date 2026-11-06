# embyx 多版本功能方案

面向 `server/`（Go + SQLite）的多版本（同一部作品的多个物理文件：不同分辨率 / 编码 / 剪辑版 / 音轨）能力设计。

本文只做设计，不含代码改动。

## 结论

现状本质是「**一个物理文件 = 一条 `items` 记录**」，而多版本要求「**一个作品 = 多个物理文件**」。这是模型层面的变化。

推荐方案：**两级模型**——`items` 继续作为「可播放条目」承担展示与查询，新增 `item_sources` 存每个物理文件；`items` 保留技术字段作为「默认版本快照」。

不推荐「`items` 上加 `group_id`、仍一文件一行」的做法：列表去重、计数、排序、筛选、续播（`user_data.item_id`）全都要 `GROUP BY`，播放进度无法在版本间共享，复杂度高且只换来"少改代码"。

## 现状事实（决定方案的前提）

| 事实 | 位置 | 影响 |
|---|---|---|
| `items` 一文件一行，技术字段（path/size/bitrate/width/height/media_streams）描述单个文件 | `internal/media/scan.go:536-564` | 必须拆表 |
| `deriveItemID` 用 tmdb/imdb 派生 ID | `internal/media/scan.go:594-611` | 同一部片两个版本会派生**相同 ID** |
| `UpsertItem` 是 `ON CONFLICT(id) DO UPDATE` | `internal/store/items.go:445` | 因此后扫到的文件**直接覆盖**前一条，两个文件互相 ping-pong。这是现存 bug |
| `items.path` 无唯一约束、无索引，无 hash 列 | `internal/store/schema.sql:30-74` | 需要一个真正的幂等键 |
| `ToDto` 的 `MediaSources` 永远只有 1 个元素 | `internal/store/items.go:802` | 协议侧是空壳 |
| `handleStream` / `handleBif` 只认 `itemId`，完全忽略 `MediaSourceId` | `internal/httpapi/playback.go:52-117` | 选版本后仍会播默认文件 |
| `PlaybackInfo` 已有 `MediaSourceId` 排序逻辑 | `internal/httpapi/playback.go:33-42` | 可直接复用 |
| 文件名解析只出标题 + 年份 | `internal/media/scan.go:650-669` | 拿不到 edition / 分辨率 / 语言 |
| `purgeMissingItems` 按 `items.path` 判断存活 | `internal/media/scan.go:341-410` | 多文件后会误删整条作品 |
| 扫描无归并概念，`Type` 硬编码 `"Movie"` | `internal/media/scan.go:541` | 无 Series/Season/Episode 层级 |
| 已有逐级迁移机制，`schemaVersion = 8` | `internal/store/store.go:37-99` | 加表成本低：升到 9 + 补一条 `8: {...}` |

## 数据模型设计

### 新增 `item_sources`

```sql
CREATE TABLE IF NOT EXISTS item_sources (
    id             TEXT PRIMARY KEY,     -- MediaSourceId
    item_id        TEXT NOT NULL,
    library_id     TEXT NOT NULL DEFAULT '',
    path           TEXT NOT NULL,
    path_key       TEXT NOT NULL,        -- lower + 正斜杠归一化，跨平台幂等键

    -- 版本语义
    label          TEXT NOT NULL DEFAULT '',  -- "2160p HEVC HDR 国语 导演剪辑版"
    edition        TEXT NOT NULL DEFAULT '',  -- 来自 NFO/文件名，ffprobe 拿不到
    resolution     TEXT NOT NULL DEFAULT '',  -- 归一化档位，便于排序筛选
    video_codec    TEXT NOT NULL DEFAULT '',
    hdr            TEXT NOT NULL DEFAULT '',  -- sdr / hdr10 / hlg / dv
    audio_langs    TEXT NOT NULL DEFAULT '[]',
    priority       INTEGER NOT NULL DEFAULT 0,
    is_default     INTEGER NOT NULL DEFAULT 0,

    -- 技术属性：从 items 整体下移
    container      TEXT NOT NULL DEFAULT '',
    size           INTEGER NOT NULL DEFAULT 0,
    bitrate        INTEGER NOT NULL DEFAULT 0,
    duration_ticks INTEGER NOT NULL DEFAULT 0,
    width          INTEGER NOT NULL DEFAULT 0,
    height         INTEGER NOT NULL DEFAULT 0,
    media_streams  TEXT NOT NULL DEFAULT '[]',
    chapters       TEXT NOT NULL DEFAULT '[]',

    -- 扫描幂等
    fingerprint    TEXT NOT NULL DEFAULT '',
    nfo_mtime      INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL DEFAULT '',
    updated_at     TEXT NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_item_sources_path ON item_sources(path_key);
CREATE INDEX IF NOT EXISTS idx_item_sources_item ON item_sources(item_id, priority DESC);
```

### 三个关键决策

**1. `path_key` 全局唯一**

这是替代「靠 item id 去重」的正确做法（现在 `items.path` 连索引都没有），解决了「同一部片两个版本互相覆盖」的根因。

选全局唯一而非 `(library_id, path_key)` 复合：同一物理文件若被两个库扫到，各存一条 source 会导致 purge 时互删。全局唯一能直接暴露冲突（记 warning 跳过），比静默放两份安全。

`path_key = strings.ToLower(filepath.ToSlash(clean(path)))`，理由与 `deriveItemID` 现有注释一致：Windows 路径大小写不敏感。

**2. `items` 保留技术列，语义固定为「默认版本快照」**

保留 `path / size / bitrate / width / height / container / media_streams`，含义固定为「优先级最高的那个 source」。理由：

- 列表、详情、排序、筛选、`ItemSource()` 的现有 SQL 一行都不用改，回归风险最低；
- 迁移是纯增量（建表 + 搬数据），可回滚；
- 客户端拿到的 `BaseItemDto.Width/Height/RunTimeTicks` 依然有正确含义。

代价是双写一致性，靠「扫描第二阶段串行聚合」保证。

**3. `MediaSourceId` 设计**

默认版本的 source id **直接复用 item id**（Emby / Jellyfin 的惯例：`MediaSourceInfo.Id` 默认等于 item id）。其余版本用 `itemID + "-" + shortHash(pathKey)`。

好处：

- 老客户端不带 `MediaSourceId` 的请求全部自然命中默认版本，行为零变化；
- `ToMediaSource()` 现在把 `ID` 写成 `item.ID`，本身就是对的。

### 迁移（schemaVersion 8 → 9）

在 `internal/store/store.go` 的 `schemaMigrations` 里补一条 `8: {...}`：

```sql
CREATE TABLE item_sources (...);

INSERT INTO item_sources (
    id, item_id, library_id, path, path_key, is_default, priority,
    container, size, bitrate, duration_ticks, width, height,
    media_streams, chapters, fingerprint, nfo_mtime
)
SELECT
    id, id, library_id, path, lower(replace(path, char(92), '/')), 1, 0,
    container, size, bitrate, run_time_ticks, width, height,
    media_streams, chapters, fingerprint, nfo_mtime
FROM items
WHERE path <> '';
```

`id = item_id` 让历史条目零成本获得一个 source，老数据行为完全不变。注意 SQL 里路径反斜杠要用 `char(92)`，不要写字面量 `'\\'`。

## 扫描识别

这是本功能真正的难点，必须分四层做，不要混在一起。

### 层 1：作品归并键（哪些文件算同一部片）

按可信度降序，**默认只信前两级**：

| 级别 | 依据 | 说明 |
|---|---|---|
| 1 | NFO 的 tmdb / imdb | 已有能力。将来要加命名空间 `tmdb:movie:123` / `tmdb:tv:456`，movie 与 tv 的 tmdb id 不是同一套 |
| 2 | 目录级 `movie.nfo` | `FindNFO` 已支持（`internal/media/nfo.go:63-75`）。**同目录多文件共享一个 `movie.nfo` 是最省事的多版本目录布局**，应作为推荐用法写进文档 |
| 3 | 归一化标题 + 年份 + 同库 | 兜底，仅在同一 `library_id` 内合并 |
| 4 | 不合并 | 宁可少并，不可错并 |

建议加配置项 `group_policy: nfo_only | nfo_and_folder | aggressive`，默认 `nfo_and_folder`。

理由：错并的后果是「用户发现少了一部片」，比「多出一部重复片」严重得多。

### 层 2：文件名版本解析

现在 `parseFileName` 只出标题和年份。需要新增一个 **hint 解析器**，输出 `Edition / Resolution / Source / VideoCodec / AudioCodec / AudioLangs / HDR / ReleaseGroup`。

一条硬原则：**解析结果只做提示，绝不覆盖 ffprobe 实测值**。分辨率、编码、HDR、声道 ffprobe 都有且更准（`internal/media/probe.go:107-187`）。

文件名解析只补 ffprobe 拿不到的三类：

- **Edition**：`Director's Cut` / `Extended` / `Unrated` / `Remastered` / `IMAX` / 导演剪辑 / 加长版 / 未删减 —— 多版本最核心的区分维度；
- **语言标记**：国语 / 粤语 / 中字 / CHS / ENG —— 决定「这部片有没有国语版」能否被筛选；
- **ReleaseGroup**：`-GROUP` 结尾。

`parseFileName` 保留为纯标题解析，避免破坏 `Name` 的现有行为；版本信息走独立的 `parseVersionHints`。

### 层 3：两阶段扫描（解决并发写冲突）

现在 `processFiles` 是 4 个 worker 边探测边 `UpsertItem`（`internal/media/scan.go:423-483`）。多版本下同一部片的两个文件可能被两个 worker 同时处理，抢写同一行 `items`，谁后写谁赢，元数据随机漂移。

改为两阶段：

**阶段 1（并发）**：`buildItem` 只产出 `(itemID, *store.MediaSource)`，按 `path_key` 做 `ON CONFLICT(path_key) DO UPDATE` 写入 `item_sources`。原子、可重复、无竞争。

**阶段 2（串行，扫描收尾）**：按 `item_id` 聚合，`ORDER BY priority DESC` 取第一条为默认，回写 `items` 的冗余列；元数据（name / overview / people / 图片归属）以默认版本的 NFO 为准。

额外好处：一部新片在阶段 2 之前不会出现在列表里，用户看不到半成品。

幂等检查沿用现有思路：把 `storedState` 的 `map[itemID]ItemScanState`（`internal/media/scan.go:50`）改成 `map[pathKey]ScanState`，结构几乎同构。

### 层 4：清理与移动

`purgeMissingItems` 目前遍历 `items.path`。改为：

- 遍历 `item_sources.path`，`os.Stat` 不存在 → 删该 source；
- `item_id` 下 source 归零 → 才删 item（连带 `user_data`、图片缓存、BIF）。

注意：库里没有外键，级联删除必须显式写。另外 `s.images.RemoveItem(itemID)` / `removeCachedBif(itemID)` 是 item 级的，删单个 source 时不应调用。

移动文件的场景：`path_key` 变化 = 新 source + 旧 source 被 purge，版本 ID 会变。如需「移动不丢」，可在同 item 内做「同 fingerprint + 同 size 的 source 重定位」，思路与现有 `UpdateItemLocation` 一致，属于可选优化。

## 版本标签与默认版本

**label 生成**：`2160p · HEVC · HDR10 · 国语/英语 · 导演剪辑版`。前缀取 ffprobe 实测值，后缀取 NFO / 文件名 hint，空项跳过。

**priority 评分**（用于选默认版本）：

```
priority = height * 1000
         + (hdr ? 5000 : 0)
         + clamp(bitrate / 1e6, 0, 999)
         + audioChannels * 10
```

同分按 `size` 降序。

**默认选最高质量**，不做码率自适应：项目 `SupportsTranscoding: false` 只走 DirectPlay（`internal/store/items.go:836`），选低了用户看着糊，选高了顶多卡一下手选，后者可恢复。

建议 `items` 加 `default_source_id TEXT`，允许手工指定。扫描只在它为空、或指向的 source 已消失时才按 priority 重算，否则尊重用户选择。

## 协议与播放层

只需动三处：

1. **`Item.ToDto`**：`MediaSources` 从单元素改为遍历 sources（`internal/store/items.go:802`）。需要批量加载，避免 N+1。
2. **`handleStream`**：先读 `?MediaSourceId=`，为空则走默认版本（`internal/httpapi/playback.go:52-82`）。客户端会传这个参数，不实现的话「选择版本后播的仍是默认文件」。
3. **`handleBif`**：缓存键从 itemID 换成 source id（`internal/httpapi/playback.go:84-117`）。不同版本时长不同，不改会出现「选 4K 版却拿到 1080p 版缩略图」。

`PlaybackInfo` 的 `MediaSourceId` 重排逻辑可以直接复用，只需注意 `sources` 为空时不要越界。

关于 `MediaSourceInfo.Type`：建议先**全部保持 `Default`**。`Grouping` 在 Emby / Jellyfin 里主要表达「多个物理分片拼成一个条目」（CD1/CD2），不是版本选择器；版本选择器只看 `Id` 唯一 + `Name` 可读。落地后用客户端实测确认，不要提前猜。

## 风险与坑

1. **图片单槽位冲突**：`items.image_tags` 是单槽位，两个版本各带 poster 会互相覆盖。必须定规则：只有默认版本的 artwork 写入 item，非默认版本的本地图忽略或移到 source 级。
2. **`item_people` 是 item 级**：两个版本 NFO 演员表不同（配音版）会互相覆盖。同样以默认版本为准。
3. **进度跨版本错位**：`user_data` 按 `item_id` 存，导演剪辑版比院线版长 20 分钟会导致续播点错位。可选缓解：`user_data` 加 `last_source_id`，续播时优先选同一版本。
4. **`ItemSource()` 语义要固定**：改为「取默认版本」（`internal/store/items.go:625`）。它被 artwork_gen / thumbnail / bif 多处调用，签名不要改，否则牵连面很大。
5. **不要在同一轮做剧集结构**：`parseFileName` 认不出 `S01E02`，`items.Type` 硬编码 `"Movie"`。剧集结构与多版本都是模型级改动，叠加后出问题难定位。schema 里 `type` / `parent_id` / `IndexNumber` 已预留，按「Movie 先跑通两级模型 → 再加 Series/Season/Episode 层级」的顺序走。
6. **展示层可选拆分**：模型是两级，但可提供配置让用户选择「合并成一个条目」或「每个版本单独显示」。后者只是不聚合 `MediaSources`，内部模型不变，成本很低，能覆盖「我想让导演剪辑版单独出现在列表里」的需求。

## 分期

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| P0 | 建 `item_sources` + 迁移老数据（source id = item id），扫描双写但每 item 仍只有 1 个 source | 全功能零回归：播放 / 列表 / 图片 / BIF 行为完全不变 |
| P1 | ID 派生拆分、`path_key` 幂等、两阶段扫描、多 source 入库、label/priority、`MediaSources` 多元素、stream/bif 按 `MediaSourceId` | 同目录放 `movie.nfo` + 两个版本文件，客户端出现版本选择，切换后播放与缩略图都正确 |
| P2 | 文件名 hint 解析（edition / 语言）、手工指定默认版本、续播记忆版本 | 版本名可读、可手动切默认 |
| P3 | 跨目录同片合并、content hash 去重、剧集结构 | — |

P0 单独成一期的理由：把最危险的模型迁移和最容易出 bug 的识别逻辑拆开。P0 出问题时可以干净回滚（`item_sources` 是纯增量表，删表即回到原状态）。

## 待决策

1. `group_policy` 默认值：`nfo_and_folder` 还是更保守的 `nfo_only`？
2. 非默认版本的本地 artwork（同目录 `poster.jpg` 之外的版本专属图）是忽略还是存 source 级？
3. 是否需要在 P1 就提供 `default_source_id` 的手工指定入口（需要前端配合）。
4. TV 结构的接入时机：P1 之后立刻做，还是先让 Movie 多版本稳定跑一段时间。
