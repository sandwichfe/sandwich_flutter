# embyx 实现说明

后端如何取封面、数据库里存了什么、数据怎么流动。

---

## 1. 组件一览

```
cmd/embyx/main.go          进程入口：配置 → 数据库 → 路由 → 监听
internal/config            配置加载（YAML + 环境变量）
internal/dto               与 Emby 协议对齐的 JSON 结构
internal/httpapi           路由、鉴权中间件、各接口处理器
internal/store             SQLite 读写（users / items / user_data / libraries）
internal/media             ffprobe 探测、NFO 解析、图片匹配与缩放、BIF
```

数据目录（`data/`）：

```
data/
├── embyx.db                        SQLite 主库
├── images/{itemId}/{type}/{index}.jpg   条目图片（自管副本）
├── users/{userId}/primary.jpg     用户头像
└── cache/bif/{itemId}.bif         进度条缩略图缓存
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
服务端读本地副本 → 按 maxWidth 缩放 → 编码 JPEG → 返回
```

关键设计：**数据库里的 tag 是"有没有图"的唯一开关**。客户端 `EmbyPcItem.hasPrimaryImage` 只看 `PrimaryImageTag` / `ImageTags['Primary']`，没有 tag 就显示占位图，连请求都不会发。所以图片文件存在但 tag 没写，客户端就是看不到。

### 2.2 命名优先级

扫描时只读视频**所在目录**，按顺序取第一个命中的文件。

| 用途 | 查找顺序（从左到右） |
|---|---|
| 海报 Primary | `<视频名>-poster` → `poster` → `folder` → `cover` → `<视频名>` → `movie` |
| 背景 Backdrop | `<视频名>-fanart` → `fanart` → `<视频名>-backdrop` → `backdrop` → `<视频名>-background` → `background` |
| 背景（带序号） | `<视频名>-fanart1..10` → `fanart1..10` → `<视频名>-backdrop1..10` → `backdrop1..10` → `extrafanart1..10` |
| 横幅 Banner | `<视频名>-banner` → `banner` |
| 缩略 Thumb | `<视频名>-thumb` → `thumb` → `landscape` |
| Logo | `<视频名>-clearlogo` → `clearlogo` → `<视频名>-logo` → `logo` |
| ClearArt | `<视频名>-clearart` → `clearart` → `characterart` |
| 光盘图 Disc | `<视频名>-disc` → `disc` → `discart` |

`<视频名>` 指去掉扩展名的完整文件名，比较时统一转小写。

只接受 `.jpg` / `.jpeg` / `.png`。`.webp` 会被跳过——标准库解不了，硬存会导致响应头声明 `image/jpeg` 但内容是 webp。

**不支持 `extrafanart/` 子目录**。如果你目录里是 `extrafanart/0.png`、`1.png`，这些不会入库；只有文件名形如 `extrafanart1.jpg` 的才会被当成第二张背景图。

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
raw, _ := s.images.LoadItemImage(itemID, imageType, index)   // 读本地副本
rendered, _ := media.Render(raw, maxWidth, quality)          // 缩放
w.Header().Set("Content-Type", "image/jpeg")
w.Header().Set("Cache-Control", "public, max-age=86400")
w.Write(rendered)
```

`media.Render`：

- `maxWidth <= 0` 或原图不宽于 maxWidth → 不缩放，直接重编码
- 否则按等比用**纯 Go 双线性插值**缩放（没有引入 libvips，见"已知限制"）
- `quality` 非法时默认 82

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

SQLite，单文件 `data/embyx.db`，WAL 模式，`SetMaxOpenConns(1)`。

### 3.1 表清单

| 表 | 行数含义 | 说明 |
|---|---|---|
| `users` | 用户 | 账号、sha256 加盐密码哈希、是否管理员、头像 tag |
| `tokens` | 登录令牌 | `token → user_id`，当前**没有过期机制** |
| `libraries` | 媒体库 | 界面创建的库，一行可挂多个目录（`paths` JSON 列） |
| `items` | 媒体条目 | 一部视频一行，29 个字段，复杂结构用 JSON 列 |
| `user_data` | 用户×条目 | 收藏、已看、播放进度、播放次数、最后播放时间 |
| `play_sessions` | 播放会话 | 目前只写不读，为后续"正在播放"看板预留 |

### 3.2 items 字段

| 字段 | 来源 | 说明 |
|---|---|---|
| `id` | `sha1("item:"+绝对路径)` 前 16 字节 | 路径不变就稳定 |
| `library_id` / `parent_id` | 扫描时传入 | 两者当前都等于所属库 ID |
| `type` | 固定 `Movie` | 剧集层级未实现 |
| `name` / `sort_name` | NFO `title`/`sorttitle`，否则文件名 | |
| `overview` | NFO `plot`（`outline` 兜底） | |
| `production_year` | NFO `year`，否则文件名里的 `(2023)` | |
| `premiere_date` / `date_created` | NFO `premiered` / `dateadded` | 统一转 UTC ISO8601 |
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
store.Open → 建表（IF NOT EXISTS）
      ↓
store.EnsureAdmin → 账号不存在才创建
      ↓
httpapi.New → 注册 32 条路由
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
   ↓ ffprobe -show_format -show_streams
   │    → 时长、容器、码率、宽高、完整流信息（编码/色彩/声道…）
   ↓ parseFileName（文件名兜底）
   │    → "标题 (2023)" / "标题.2023.1080p" → 标题 + 年份
   ↓ FindNFO → ParseNFO
   │    → 标题/简介/流派/演员/外部 ID（覆盖文件名推断，空值不覆盖）
   ↓ FindArtwork + FindActorImages
   │    → 图片转码落盘，得到 tag
   ↓ store.UpsertItem（INSERT ... ON CONFLICT(id) DO UPDATE）
   ↓
items 表
```

**幂等性**：条目 ID 由绝对路径派生，同一路径重复扫描只会 UPDATE，不会插入重复行。改名会导致 ID 变化，旧记录会残留（目前没有清理机制）。

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

**人物是特例**：`IncludeItemTypes=Person` 时不查 items 表，而是遍历所有 `items.people` JSON 聚合去重。`Filters=IsFavorite` 会先查 `user_data` 里的收藏集合再过滤。

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
   ↓ 缓存命中 data/cache/bif/{itemId}.bif → 直接返回
   ↓ 媒体目录有预生成的 *.bif → 复制进缓存（网络盘上省掉抽帧）
   ↓ 都没有 → ffmpeg 每 10 秒抽一帧 → 打包成 BIF
```

---

## 5. ID 规则

所有 ID 都是 32 位十六进制字符串，由 `sha1(种子) 前 16 字节` 派生：

| 对象 | 种子 | 稳定性 |
|---|---|---|
| 媒体库 | 随机 | — |
| 条目 | `item:` + 视频绝对路径 | 改名/移动会变 |
| 人物 | `person:` + 姓名 | 姓名不变就稳定 |
| 工作室 | `studio:` + 名称 | 稳定 |
| 用户 / 令牌 | 随机 | — |

路径类 ID 由路径派生，好处是扫描天然幂等；代价是文件改名后会变成新条目，旧记录残留。

---

## 6. 已知限制

| 项 | 现状 | 影响 |
|---|---|---|
| 图片缩放 | 纯 Go 双线性，无缓存 | 1600px 宽约 100–300ms，并发高时 CPU 吃紧 |
| 图片换新 | URL 里 `v` 参数客户端传空 | 换了海报后客户端可能仍显示旧图，需重启客户端 |
| `extrafanart/` 子目录 | 不支持 | 多背景图只能靠 `fanart1.jpg` 这种命名 |
| `.webp` | 跳过 | 只处理 jpg/jpeg/png |
| 章节 | 未实现 | 详情页章节列表为空；`chapters` 恒为 `[]` |
| 剧集层级 | 未实现 | 视频统一按 `Movie` 入库，没有 Season/Episode |
| token 过期 | 未实现 | `token_ttl` 配置项目前不生效 |
| 改名清理 | 未实现 | 文件改名后旧条目残留在库里 |
| 转码 | 未实现 | 只支持 DirectPlay，编码不被 mpv 支持时播不了 |
| 人物表 | 从 JSON 聚合 | 条目多了以后 `/Persons` 会变慢，需要拆表 |
