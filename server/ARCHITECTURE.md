# embyx 实现说明

后端如何取封面、数据库里存了什么、数据怎么流动。

---

## 1. 组件一览

```
cmd/embyx/main.go          进程入口：配置 → 数据库 → 路由 → 监听
internal/config            配置加载（YAML + 环境变量）
internal/dto               与 Emby 协议对齐的 JSON 结构
internal/httpapi           路由、鉴权中间件、各接口处理器
internal/store             SQLite 读写（users / items / persons / item_people / user_data / libraries）
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

### 2.6 演员头像与写真

和条目图片是同一套机制，只是目录换了：

```
.actors/萨姆·沃辛顿.jpg              → 头像 Primary
.actors/萨姆·沃辛顿-fanart.jpg       → 写真 Backdrop 0
.actors/萨姆·沃辛顿-fanart2.jpg      → 写真 Backdrop 1
.actors/萨姆·沃辛顿-backdrop1.jpg    → 写真 Backdrop 2（-fanart 系列优先，组内自然序）
   ↓ personID = sha1("person:" + 姓名) 前 16 字节 → 32 hex
   ↓ data/images/{personID}/primary/0.jpg 与 /backdrop/{n}.jpg
   ↓ tag 写回 persons.image_tag 与 persons.backdrop_tags
```

因为人物 ID 由姓名派生，同一演员在多部片子里是同一个 ID，头像与写真只存一份。客户端请求 `/Items/{personID}/Images/Primary`、`/Images/Backdrop/{n}` 就能拿到。

写真文件不会被当成头像（`readActorIndex` 会跳过 `-fanart` / `-backdrop` 后缀）。手动上传/删除走同一套图片接口：`POST|DELETE /emby/Items/{personId}/Images/{Primary|Backdrop}/{index}`，落盘后会回写 `persons` 的图片标记。

### 2.7 演员刮削（TMDB，手动触发）

扫描流程**不联网**；演员资料只在设置页点「开始刮削」或人物页点「从 TMDB 刮削」时才去取。

```
PersonScrapeJobManager（串行，同刻只跑一个任务）
   ↓ 候选来自 persons（item_count > 0，missing 模式只挑没编号/没刮过的）
   ↓ resolveTmdbID：已有 Tmdb 编号 → 关联影片 /movie/{id}/credits 反查 → 姓名搜索 + 作品交叉验证
   ↓ /person/{id} + /external_ids + /images（≤ tmdb.max_backdrops 张写真）
   ↓ ApplyScrapedPerson（manual_fields 保护手动字段；force 才覆盖已有值）
   ↓ 图片落 data/images/{personID}/，tag 回写 persons
```

| 接口 | 说明 |
|---|---|
| `POST /emby/PersonScrapeJobs` | 正文 `{"Mode":"all"\|"missing","Force":false}` |
| `GET /emby/PersonScrapeJobs` | 返回 `{Configured, Jobs}`，前端据此提示"未配置 Key" |
| `GET /emby/PersonScrapeJobs/{jobId}` | 轮询进度 |
| `POST /emby/PersonScrapeJobs/{jobId}/Cancel` | 取消 |
| `POST /emby/Persons/{personId}/Scrape` | 单个人物，正文可选 `{"Force":true}` |

覆盖规则：

- `manual_fields` 记录被手动编辑过的字段（`UpdatePersonMetadata` 写入），刮削**永不覆盖**这些字段，即使 `Force=true`
- 未锁定字段默认**只补空值**，`Force=true` 才用 TMDB 数据覆盖
- 图片：`image_locks` 锁定的实体整段跳过；用户上传/生成的图不覆盖，本地导入与上次刮削的图可刷新
- 重名无法唯一确定（`match_state=ambiguous`）时不写任何资料，只记录状态，避免张冠李戴

配置项（`config.yaml`，也可用环境变量）：

```yaml
tmdb:
  api_key: ''        # EMBYX_TMDB_API_KEY，空表示未启用
  language: zh-CN    # 简介为空自动回退 en-US
  proxy: ''          # EMBYX_TMDB_PROXY，国内网络通常必填
  rate_limit: 4      # 每秒请求上限，1~10，超过按 10 处理
  max_backdrops: 6   # 0 表示不下写真
```

**为什么不会被限流/封禁**

- 任务本身串行：`PersonScrapeJobManager` 同一时刻只允许一个刮削任务，不会有 N 个任务并发打接口
- 全局限速：所有请求（含图片 CDN）统一走 `waitTurn`，默认 4 次/秒，只有官方上限（50/秒）的 8%；`rate_limit` 可调但硬上限 10
- 命中 429 时**整个客户端一起冷却**（遵守 `Retry-After`，退避 1s/2s/3s 重试 3 次），不会以原速率继续猛打
- 影片演职员表有进程内缓存（上限 500 部），同一部片的演员不会重复拉 credits
- 冒烟测试：`TestClientRateLimitSpacing` 校验请求间隔、`TestClientRetryAfterCooldown` 校验 429 退避

按默认 4 次/秒估算，1000 位演员约需 40～60 分钟（每人 4～10 个请求，含图片）。TMDB 要求在产品中署名其数据来源。

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
| `persons` | 演员主表 | 演员是独立主体：姓名、头像 tag、写真、生日、首映日期、性别、罩杯、简介、`provider_ids`（Tmdb/Imdb）、作品数；`/Persons` 直接分页查它，**删片不删演员** |
| `item_people` | 演员×条目 | 纯关联表，`(item_id, person_id, type, role)` 唯一；`items.people` 的 JSON 只作入库快照 |
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
| `people` | NFO `actor`/`director`/`credits` | JSON 快照；展示以 `persons` 主表为准 |
| `chapters` | 未实现 | 恒为 `[]` |
| `provider_ids` | NFO `uniqueid` | JSON，键名归一为 `Tmdb`/`Imdb`/`Tvdb` |
| `external_urls` | 未实现 | 恒为 `[]` |
| `image_tags` | 图片入库 | JSON 对象 |
| `backdrop_tags` | 图片入库 | JSON 数组 |
| `screenshot_tags` | 未实现 | 恒为 `[]` |
| `fingerprint` | 扫描时算 `size:mtime` + `extrafanart` 摘要 | 重复扫描命中就跳过 ffprobe 与图片导入 |
| `nfo_mtime` | NFO 修改时间（纳秒） | 视频没动但 NFO 改了也要重新入库 |

#### persons 字段与扫描的关系

**扫描只维护「演员 × 条目」的关联，不写演员资料。** 标准 NFO 的 `<actor>` 本来只有
`name` / `role` / `order` / `thumb`，`<type>` 是 Emby/Jellyfin 的扩展写法；生日、简介、
性别、罩杯、Tmdb/Imdb 这些要么没有，要么只有少数刮削器写，靠它入库只会把人工整理好的
信息越扫越少。所以职责这样分：

| 数据 | 来源 | 说明 |
|---|---|---|
| `name` / `role` / `item_people.type` / `sort_order` | 扫描 | `name` 同时是演员 ID 的种子；`type` 认不出时按 Actor，排序兼容 `<order>` 与 `<sortorder>` |
| `image_tag` / `backdrop_tags` | 扫描（本地文件） | 来自 `.actors/` 下的头像与写真，有值才覆盖 |
| `item_people` 的增删 | 扫描 | 每次入库按当前 NFO 重建该条目的关联 |
| `birth_date` / `premiere_date` / `gender` / `cup_size` / `overview` / `provider_ids` | 人物编辑接口 | `POST /emby/Items/{personId}`；重扫永远不会改动这些列 |
| 演员行本身 | 只增不删 | 删片只清关联，演员与头像缓存保留 |

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
   ↓ FindArtwork + FindActorImages + FindActorFanarts
   │    → 条目图片、演员头像与写真转码落盘，得到 tag
   ↓ store.UpsertItem（单事务：items + persons + item_people）
   ↓
items / persons / item_people
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

**演员以主表为准**：`IncludeItemTypes=Person` 与 `/Persons` 都走 `persons`（SQL 分页 + `name LIKE`，只列 `item_count > 0` 的），`PersonIds` 过滤走 `item_people` 的 `EXISTS` 子查询。入库时只做「缺演员就建行 + 重建关联 + 有本地图片就更新」，演员资料不在扫描里改；条目详情里的演职人员同样从 `persons` + `item_people` 读，`items.people` 的 JSON 退化为扫描快照。删除条目只删关联行，演员行与头像缓存都保留。`Filters=IsFavorite` 仍是先在 `user_data` 里取收藏集合再过滤。

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
客户端「观看历史」= GET /Users/{id}/Items/Watched
   ↓ 筛选 last_played_date 非空（看没看完都保留），按 last_played_date 倒序
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
