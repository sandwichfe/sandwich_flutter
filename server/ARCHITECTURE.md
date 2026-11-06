# embyx 实现说明

后端如何取封面、数据库里存了什么、数据怎么流动。

---

## 1. 组件一览

```
cmd/embyx/main.go          进程入口：配置 → 数据库 → 路由 → 监听
internal/config            配置加载（YAML + 环境变量）
internal/dto               与 Emby 协议对齐的 JSON 结构
internal/httpapi           路由、鉴权中间件、各接口处理器
internal/store             SQLite 读写（users / items / item_people / person_view / user_data / libraries）
internal/media             ffprobe 探测、NFO 解析、图片匹配与缩放、BIF
```

数据目录（`data/`）：

```
data/
├── embyx.db                        SQLite 主库
├── images/{itemId}/{type}/{index}.jpg   条目图片（自管副本）
├── users/{userId}/primary.jpg     用户头像
├── cache/images/{itemId}/{类型}-{序号}-{源图tag}-w{宽}-q{画质}.jpg   缩放结果缓存
└── cache/bif/{itemId}-w{宽}-i{间隔毫秒}.bif   进度条缩略图缓存（文件名带参数）
```

---

## 2. 封面是怎么取的

### 2.1 三个角色

截图里的"封面"经过三段处理，**不是直接把媒体目录里的图甩给客户端**：

```
媒体目录里的原图
   ↓ 扫描时按命名规则匹配（FindArtwork）
   ↓ 转码为 JPEG 落到 data/images/{itemId}/primary/0.jpg
   ↓ 把内容哈希写进 items.image_tags
   ↓
客户端看到 ImageTags.Primary 非空 → 才去请求图片
   ↓ GET /emby/Items/{id}/Images/Primary?api_key=…&maxWidth=720&quality=82
   ↓
服务端读本地副本 → 按 maxWidth 缩放（命中磁盘缓存则直接读缓存）→ 返回 JPEG + ETag
```

关键设计：**数据库里的 tag 是"有没有图"的唯一开关**。客户端 `EmbyPcItem.hasPrimaryImage` 只看 `PrimaryImageTag` / `ImageTags['Primary']`，没有 tag 就显示占位图，连请求都不会发。所以图片文件存在但 tag 没写，客户端就是看不到。

### 2.2 命名优先级

扫描时只读视频**所在目录**，按顺序取第一个命中的文件。

| 用途 | 查找顺序（从左到右） |
|---|---|
| 海报 Primary | `<视频名>-poster` → `poster` → `folder` → `cover` → `<视频名>` → `movie` |
| 背景 Backdrop | `<视频名>-fanart` → `fanart` → `<视频名>-backdrop` → `backdrop` → `<视频名>-background` → `background` |
| 背景（带序号） | `<视频名>-fanart1..10` → `fanart1..10` → `<视频名>-backdrop1..10` → `backdrop1..10` → `extrafanart1..10` |
| 艺术图（子目录） | `<视频名>-extrafanart/` → `extrafanart/`（目录内所有 jpg/jpeg/png，按文件名自然排序，追加在同目录背景图之后） |
| 横幅 Banner | `<视频名>-banner` → `banner` |
| 缩略 Thumb | `<视频名>-thumb` → `thumb` → `landscape` |
| Logo | `<视频名>-clearlogo` → `clearlogo` → `<视频名>-logo` → `logo` |
| ClearArt | `<视频名>-clearart` → `clearart` → `characterart` |
| 光盘图 Disc | `<视频名>-disc` → `disc` → `discart` |

`<视频名>` 指去掉扩展名的完整文件名，比较时统一转小写。

只接受 `.jpg` / `.jpeg` / `.png`。`.webp` 会被跳过——标准库解不了，硬存会导致响应头声明 `image/jpeg` 但内容是 webp。

`extrafanart/` 子目录是支持的：目录里所有 `.jpg/.jpeg/.png` 按文件名自然排序（`fanart2` 在 `fanart10` 之前）依次追加为 Backdrop，序号接在同目录背景图之后，所以 0 号槽位（详情页顶部大图）仍然优先由 `fanart.jpg` 一类文件占用。同目录多部片时优先用 `<视频名>-extrafanart/`，没有才回退到整目录共用的 `extrafanart/`。

`extrafanart/` 的内容摘要（张数 + 各图体积/修改时间之和）会并进 `items.fingerprint`：只要增删改过艺术图，重新扫描就会重跑一次图片导入。源端删图后，多出来的 Backdrop 槽位会被清理（用户上传 / 视频生成的图不清理）。

查看你当前目录的实际匹配结果：`IPX712.[4K]-poster.jpg` 会命中 `<视频名>-poster`，`fanart.jpg` 命中 `fanart`。

### 2.3 入库时做了什么

```go
// internal/media/ingest.go
func (s *Scanner) saveArtwork(itemID, imageType string, index int, sourcePath string) (string, error) {
	target := s.images.ItemPath(itemID, imageType, index)  // data/images/{id}/{type}/{index}.jpg
	if isUpToDate(target, sourcePath) {                    // 目标 mtime >= 源 mtime 直接复用
		raw, _ := os.ReadFile(target)
		return hashTag(raw), nil
	}
	raw, _ := os.ReadFile(sourcePath)
	return s.images.SaveItemImage(itemID, imageType, index, raw)
}
```

`SaveItemImage` 内部：

1. 写入前先 `transcodeToJPEG`：源是 JPEG 就原样保存；PNG/GIF 解码后按质量 92 重编码为 JPEG
2. 落盘到 `data/images/{itemID}/{type小写}/{index}.jpg`
3. 返回 `tag = sha1(文件内容) 前 8 字节的十六进制`（16 个字符）

**幂等**：靠 mtime 判断，重复扫描不会反复转码。源图更新后 mtime 变新，才会重新转码并生成新 tag。

落库：

| 图片类型 | 写入字段 | 形态 |
|---|---|---|
| Primary / Logo / Thumb / Banner / Disc / Art | `items.image_tags` | JSON 对象 `{"Primary":"a1b2...","Logo":"..."}` |
| Backdrop | `items.backdrop_tags` | JSON 数组 `["a1b2...","c3d4..."]` |
| Screenshot | `items.screenshot_tags` | JSON 数组（目前只有手工上传才会写） |

### 2.4 客户端怎么拼 URL

```dart
// emby_pc_service.dart:466
String imageUrl(String itemId, {String type = 'Primary', int index = 0,
    int maxWidth = 720, String cacheKey = ''}) {
  final path = type == 'Primary'
      ? '/emby/Items/$itemId/Images/Primary'
      : '/emby/Items/$itemId/Images/$type/$index';
  return _uri(path, {
    'api_key': accessToken,     // 图片走 query 鉴权，因为 Image.network 加不了 header
    'maxWidth': '$maxWidth',
    'quality': '82',
    if (cacheKey.isNotEmpty) 'v': cacheKey,
  }).toString();
}
```

不同位置的 `maxWidth`：列表卡片 420/640、详情页背景 1600、章节图 640、人物头像 260/520。

### 2.5 服务端怎么响应

```go
// internal/httpapi/images.go
raw, _ := s.loadItemImage(r, itemID, imageType, index)   // 目录图 / 生成图按库偏好取，互相兜底
maxWidth := media.NormalizeRenderWidth(...)              // 0 表示原宽，上限 2000
quality := media.NormalizeRenderQuality(...)             // 非法值回落 82
rendered, tag, _ := s.imageRenderer.Render(itemID, imageType, index, raw, maxWidth, quality)
etag := fmt.Sprintf(`"%s-w%d-q%d"`, tag, maxWidth, quality)
w.Header().Set("ETag", etag)                              // 与 If-None-Match 相同 → 304
w.Header().Set("Content-Type", "image/jpeg")
w.Header().Set("Cache-Control", "public, max-age=86400")
w.Write(rendered)
```

`media.ImageRenderer`（S2 引入，`internal/media/imagecache.go`）：

| 项 | 实现 |
|---|---|
| 磁盘缓存 | `data/cache/images/{itemId}/{类型}-{序号}-{源图tag}-w{宽}-q{画质}.jpg`，命中直接读文件 |
| 回收 | `CacheJanitor`（`media/cachegc.go`）：删孤儿目录/文件，超上限按 LRU（条目目录）与旧到新（BIF）淘汰，间隔取 `cache.sweep_interval` |
| 失效 | key 里带源图内容 tag，换图后旧文件自然不再命中；上传/删除图片时按 itemId 清整个目录 |
| ETag | 源图 tag + 宽 + 画质，带 `If-None-Match` 时返回 304 |
| 并发 | semaphore 按 `runtime.NumCPU()` 限流；自实现 singleflight 合并同 key 请求 |
| 缩放 | 源图先转 `*image.RGBA`，按像素切片索引 + 整数定点权重做双线性插值 |
| 宽度上限 | 2000，超出按 2000 处理 |

`maxWidth <= 0` 或原图不宽于 maxWidth 时不缩放，只重编码；`quality` 非法时默认 82。

`handleImage` 同时接受 `maxWidth` 和 `MaxWidth` 两种写法（条目图片用小写，用户头像用大写，不同接口约定不一致）。

### 2.6 演员头像

和条目图片是同一套机制，只是目录换了：

```
.actors/萨姆·沃辛顿.jpg
   ↓ personID = sha1("person:" + 姓名) 前 16 字节 → 32 hex
   ↓ data/images/{personID}/primary/0.jpg
   ↓ tag 写回 items.people 里该人物的 PrimaryImageTag / ImageTags
```

因为人物 ID 由姓名派生，同一演员在多部片子里是同一个 ID，头像只存一份。客户端请求 `/Items/{personID}/Images/Primary` 就能拿到。

---

## 3. 数据库存了什么

SQLite，单文件 `data/embyx.db`，WAL 模式。

连接池（S2）：`SetMaxOpenConns(runtime.NumCPU())`（最小 2）。`busy_timeout` / `synchronous` / `foreign_keys` 都是**每连接** PRAGMA，写在 DSN 里由驱动逐连接应用：

```
file:<path>?_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(1)
```

`journal_mode=WAL` 是写进数据库文件的持久设置，启动时执行一次即可。

### 3.1 表清单

| 表 | 行数含义 | 说明 |
|---|---|---|
| `users` | 用户 | 账号、sha256 加盐密码哈希、是否管理员、头像 tag |
| `tokens` | 登录令牌 | `token → user_id`，当前**没有过期机制** |
| `libraries` | 媒体库 | 界面创建的库，一行可挂多个目录（`paths` JSON 列） |
| `items` | 媒体条目 | 一部视频一行，复杂结构用 JSON 列 |
| `item_people` | 条目×人物 | `items.people` 拆出来的查询副本，供按人物筛选与聚合 |
| `person_view` | 人物汇总 | 姓名、头像 tag、作品数，`/Persons` 直接分页查它 |
| `user_data` | 用户×条目 | 收藏、已看、播放进度、播放次数、最后播放时间 |
| `play_sessions` | 播放会话 | 目前只写不读，为后续"正在播放"看板预留 |

### 3.2 items 字段

| 字段 | 来源 | 说明 |
|---|---|---|
| `id` | `sha1(种子)` 前 16 字节：NFO 有 TMDB/IMDb 时用 `tmdb:`/`imdb:`，否则 `item:` + 库 ID + 相对库根路径 | 有外部编号时改名、换盘都不变 |
| `library_id` / `parent_id` | 扫描时传入 | 两者当前都等于所属库 ID |
| `type` | 固定 `Movie` | 剧集层级未实现 |
| `name` / `sort_name` | NFO `title`/`sorttitle`，否则文件名 | |
| `overview` | NFO `plot`（`outline` 兜底） | |
| `production_year` | NFO `year`，否则文件名里的 `(2023)` | |
| `premiere_date` / `date_created` | NFO `premiered` / `dateadded` | 统一转 UTC ISO8601；`date_created` 只在首次入库时写入，重扫保留原值 |
| `community_rating` | NFO `rating` 或 `ratings/rating/value` | |
| `official_rating` | NFO `mpaa` | |
| `run_time_ticks` | **优先 ffprobe**，NFO `runtime` 仅兜底 | 1 tick = 100ns |
| `width` / `height` | ffprobe 首个视频流 | |
| `path` | 视频绝对路径 | 播放时直接开这个文件 |
| `container` / `size` / `bitrate` | ffprobe `format` | |
| `media_streams` | ffprobe 全量流信息 | JSON，转成 `MediaStreams` 返回 |
| `genres` / `tags` / `studios` | NFO | JSON |
| `people` | NFO `actor`/`director`/`credits` | JSON，含角色、类型、头像 tag |
| `chapters` | 未实现 | 恒为 `[]` |
| `provider_ids` | NFO `uniqueid` | JSON，键名归一为 `Tmdb`/`Imdb`/`Tvdb` |
| `external_urls` | 未实现 | 恒为 `[]` |
| `image_tags` | 图片入库 | JSON 对象 |
| `backdrop_tags` | 图片入库 | JSON 数组 |
| `screenshot_tags` | 未实现 | 恒为 `[]` |
| `fingerprint` | 扫描时算 `size:mtime` + `extrafanart` 摘要 | 重复扫描命中就跳过 ffprobe 与图片导入 |
| `nfo_mtime` | NFO 修改时间（纳秒） | 视频没动但 NFO 改了也要重新入库 |

### 3.3 一条真实记录长什么样

```jsonc
{
  "id": "0f3c8a1d5b7e9c2a4d6f8b0e1c3a5d7f",
  "library_id": "9a2b...",
  "parent_id": "9a2b...",
  "type": "Movie",
  "name": "SNOS-131 快感强烈到足以击垮终极女英雄！…",
  "overview": "…",
  "production_year": 2023,
  "run_time_ticks": 72000000000,          // 2 小时
  "path": "\\\\192.168.31.27\\外接存储…\\SNOS-131.[4K].mp4",
  "media_streams": [
    { "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160,
      "BitRate": 40000000, "DisplayTitle": "2160p HEVC HDR" },
    { "Type": "Audio", "Codec": "eac3", "Channels": 2, "Language": "jpn" }
  ],
  "people": [
    { "Id": "7a4aa73e5e6a8c748ce4361b66388827", "Name": "萨姆·沃辛顿",
      "Role": "Jake Sully", "Type": "Actor",
      "PrimaryImageTag": "4bcb45b5d29955ca",
      "ImageTags": { "Primary": "4bcb45b5d29955ca" } }
  ],
  "provider_ids": { "Tmdb": "19995", "Imdb": "tt0499549" },
  "image_tags": { "Primary": "fc6c7c05acc05352", "Logo": "..." },
  "backdrop_tags": ["a1b2c3d4e5f60718"]
}
```

`user_data` 是独立表，按 `(user_id, item_id)` 存：

```
is_favorite | played | playback_position_ticks | play_count | last_played_date
```

---

## 4. 数据流转

### 4.1 启动

```
config.Load
  ├─ 读 config.yaml（不存在则生成模板）
  ├─ 环境变量覆盖
  ├─ 数据目录相对→绝对
  └─ 创建 data/ 子目录
      ↓
store.Open → 版本守卫：全新库按 schema.sql 建到最新版本并写 user_version，
             已有库版本不一致直接报错（不提供数据迁移，删库重扫）
      ↓
store.EnsureAdmin → 账号不存在才创建
      ↓
httpapi.New → 注册认证 / 媒体库 / 条目 / 分类浏览 / 图片 / 播放路由
      ↓
ListenAndServe :8096
```

启动时既不初始化也不扫描媒体库：库列表全部来自数据库，由客户端「设置 → 媒体库管理」
（`Library/VirtualFolders` 接口）创建和维护；扫描由 `POST /Library/Refresh` 或
`POST /Items/{id}/Refresh`（id 为媒体库时）异步触发。

### 4.2 扫描入库

```
扫描目标的媒体库目录（libraries.paths）
   ↓ filepath.WalkDir（递归，跳过 @eaDir / $RECYCLE.BIN 等）
视频文件（.mkv .mp4 .avi .mov .wmv .ts .m2ts .flv .webm .rmvb）
   ↓ FindNFO → ParseNFO
   │    → 标题/简介/流派/演员/外部 ID；NFO 决定条目 ID，必须在探测前解析
   ↓ deriveItemID（TMDB → IMDb → 库 ID + 相对库根路径）
   ↓ 比对 fingerprint（size:mtime + extrafanart 摘要）与 nfo_mtime
   │    命中 → 只 UPDATE 路径与库归属，跳过下面全部步骤
   ↓ ffprobe -show_format -show_streams
   │    → 时长、容器、码率、宽高、完整流信息（编码/色彩/声道…）
   ↓ parseFileName（文件名兜底）
   │    → "标题 (2023)" / "标题.2023.1080p" → 标题 + 年份
   ↓ FindArtwork + FindActorImages
   │    → 图片转码落盘，得到 tag
   ↓ store.UpsertItem（单事务：items + item_people + person_view）
   ↓
items / item_people / person_view
```

**幂等性**：条目 ID 有外部编号时由编号派生，没有时由「库 ID + 相对库根路径」派生，重复扫描只会 UPDATE。改名后：ID 不变时只纠正路径；ID 变了则旧条目会在下次扫描时因为源文件不存在被清理（连同图片、BIF 缓存与用户数据）。

### 4.3 认证

```
POST /emby/Users/AuthenticateByName  {Username, Pw}
   ↓ users 表按 name 查（COLLATE NOCASE）
   ↓ sha256(salt + password) 常量时间比对
   ↓ tokens 表插入新 token
   ↓ 返回 {User, AccessToken}
客户端把 token 存 SharedPreferences
   ↓
后续请求：X-Emby-Token 头 或 api_key 查询参数
   ↓ withAuth 中间件 → tokens JOIN users → 塞进 context
```

两个鉴权入口必须都支持：客户端调 API 时用 header，而 `Image.network` 和播放器只能拼 URL，所以用 `api_key`。

### 4.4 列表查询

```
GET /emby/Users/{userId}/Items?ParentId=…&IncludeItemTypes=Movie&SortBy=…&Limit=…
   ↓
解析参数 → store.ItemQuery
   ↓ SQL：
     SELECT i.*, COALESCE(ud.*)
     FROM items i
     LEFT JOIN user_data ud ON ud.item_id = i.id AND ud.user_id = ?
     WHERE (i.parent_id = ? OR i.library_id = ?)     ← 库内浏览
       AND i.type IN (…)                              ← IncludeItemTypes
       AND (i.name LIKE ? OR …)                       ← SearchTerm
       …
     ORDER BY <白名单列> + i.id                        ← 稳定分页
     LIMIT ? OFFSET ?
   ↓ 逐行 scan → JSON 列反序列化 → store.Item
   ↓ Item.ToDto(UserData) → dto.BaseItemDto
   ↓ JSON 响应 {Items, TotalRecordCount}
```

排序走白名单映射（`SortName`/`DateCreated`/`PremiereDate`/`CommunityRating`/`Runtime`/`Height`/`ProductionYear`/`DatePlayed`），不接受任意列名，避免 SQL 注入。

`ParentId` 过滤写成 `parent_id = ? OR library_id = ?`，是为了兼容早期数据——老条目只有 `library_id`，`parent_id` 是空的。

**人物不再读 JSON**：`IncludeItemTypes=Person` 与 `/Persons` 都走 `person_view`（SQL 分页 + `name LIKE`），`PersonIds` 过滤走 `item_people` 的 `EXISTS` 子查询。`items.people` 的 JSON 只作为详情页展示与扫描写入的权威数据保留。`Filters=IsFavorite` 仍是先在 `user_data` 里取收藏集合再过滤。

`GenreIds` / `TagIds` 用 `json_each` 匹配名称，`StudioIds` 匹配 JSON 里的 `Id`；`Filters` 另外支持 `IsPlayed` / `IsUnplayed` / `IsResumable`，`MinCommunityRating` 为可选浮点阈值。

### 4.5 详情

```
GET /emby/Users/{userId}/Items/{itemId}
   ↓ items 表查不到 → 走 PersonByID（人物条目不在 items 表）
   ↓ Item.ToDto：附带构造 MediaSources（含 MediaStreams）
   ↓ 客户端详情页渲染：背景图、简介、演职员、章节、技术信息
```

`MediaSources` 是详情页和 `PlaybackInfo` 共用的数据结构，`MediaStreams` 里的编码/码率/色彩信息全部来自 ffprobe 原样透传。

### 4.6 播放与进度

```
POST /Items/{itemId}/PlaybackInfo
   ↓ 返回 MediaSources[]（SupportsDirectPlay=true，SupportsTranscoding=false）
   ↓ 客户端取 MediaSourceId 选版本
      ↓
media_kit 打开 GET /Videos/{id}/stream?static=true&api_key=…
   ↓ http.ServeContent(file)  ← 自动处理 Range / 206 / If-Modified-Since
   ↓ mpv 边下边播，拖动进度条就是发新的 Range 请求
      ↓
每 10 秒 POST /Sessions/Playing/Progress
起播     POST /Sessions/Playing
退出     POST /Sessions/Playing/Stopped
   ↓ store.SavePlaybackProgress
   ↓ user_data 更新 playback_position_ticks / last_played_date / played
      ↓
客户端「继续观看」= GET /Users/{id}/Items/Resume
   ↓ 筛选 playback_position_ticks > 0 AND played = 0，按 last_played_date 倒序
```

播放进度规则：`Stopped` 时位置达到 90% 视为看完，`played=1` 且续播位置清零。

进度条缩略图（BIF）：

```
GET /Videos/{id}/index.bif?Width=320
   ↓ Lookup：参数完全一致 → 其它参数 → 早期无参数命名，命中即返回 200
   ↓ 媒体目录里有预生成的 *.bif → 复制进缓存（网络盘上省掉抽帧）
   ↓ 都没有 → EnsureAsync 只登记一次后台任务，本次立即返回 202 + Retry-After: 30
   ↓ 后台任务挂在服务根 context 上：ffmpeg 每 10 秒抽一帧 → 打包 BIF → 下次请求就是 200
```

首次播放不再等抽帧：播放器这一轮降级成普通进度条，前端拿到非 200 就不显示预览。

抽帧命令末尾的 `format=yuvj420p` 是必需的：ffmpeg 7 的 mjpeg 编码器拒绝非 full-range YUV。片长不足一个抽帧间隔时 `fps` 过滤器一帧都不输出，编码器仍按默认参数初始化并直接报错，「至少取首帧」的兜底根本走不到——3 秒短片必然失败。

### 4.7 分类浏览与最新条目

```
GET /emby/Genres | /emby/Tags | /emby/Studios?ParentId=…
   ↓ items, json_each(i.genres|i.tags|i.studios)
   ↓ GROUP BY 值/名称 → {Id, Name, Type, ChildCount}
      ↓ 前端筛选栏把 Id 原样回传到 GenreIds / TagIds / StudioIds

GET /emby/Users/{id}/Items/Latest?Limit=&ParentId=
   ↓ 复用 QueryItems（date_created DESC + id 兜底排序）
   ↓ 直接返回数组（Emby 语义），Limit 默认 20 / 上限 100
```

流派与标签的 `Id` 就是名称本身（库里没有独立主键），工作室沿用 `StableID("studio:"+名称)`。

### 4.8 扫描进度

```
GET /emby/Library/ScanStatus（管理员）
   ↓ media.Scanner 内部 scanProgress（互斥锁保护）
   ↓ running / libraryId / libraryName / scanned / total / currentPath
   ↓ failures（buildItem 与 UpsertItem 的失败，最多 200 条）
   ↓ startedAt / finishedAt（UTC RFC3339，未开始/未结束为空串）
```

---

## 5. ID 规则

所有 ID 都是 32 位十六进制字符串，由 `sha1(种子) 前 16 字节` 派生：

| 对象 | 种子 | 稳定性 |
|---|---|---|
| 媒体库 | 随机 | — |
| 条目 | `tmdb:` + TMDB 编号 → `imdb:` + IMDb 编号 → `item:` + 库 ID + 相对库根路径（小写、正斜杠） | 有外部编号时改名、换盘都不变 |
| 人物 | `person:` + 姓名 | 姓名不变就稳定 |
| 工作室 | `studio:` + 名称 | 稳定 |
| 用户 / 令牌 | 随机 | — |

同一影片放 1080p / 4K 两份时，只要 NFO 带同一个 TMDB 编号就会算出同一个 ID，不会重复入库。纯路径派生的条目在改名后会变成新条目，旧记录由扫描后的陈旧条目清理负责回收。

---

## 6. 已知限制

| 项 | 现状 | 影响 |
|---|---|---|
| 图片缩放 | 纯 Go 双线性 + 磁盘缓存 | 首次 1600px 约 110ms，命中缓存约 13ms |
| 图片换新 | 客户端图片 URL 已统一带 `v={tag}`（S5.8） | 服务端换图后 URL 变化，Flutter 缓存自动失效 |
| `extrafanart/` 子目录 | 支持，作为 Backdrop 追加 | 艺术图数量受磁盘缓存容量策略约束 |
| `.webp` | 跳过 | 只处理 jpg/jpeg/png |
| 章节 | 未实现 | 详情页章节列表为空；`chapters` 恒为 `[]` |
| 剧集层级 | 未实现 | 视频统一按 `Movie` 入库，没有 Season/Episode |
| token 过期 | 未实现 | `token_ttl` 配置项目前不生效 |
| 转码 | 未实现 | 只支持 DirectPlay，编码不被 mpv 支持时播不了 |
| 缓存回收 | `CacheJanitor` 定时清理孤儿与超量缓存（S4） | 孤儿/换参数产生的旧文件最多滞留一个巡检周期 |
