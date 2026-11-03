# 自建媒体服务器后端调研（Emby 兼容）

> 依据：`lib/pages/emby-pc/` 现有客户端代码的全部网络调用与 JSON 字段依赖。
> 目标：用自研后端替代 Emby Server，保持现有 Flutter 客户端零改动。

## 1. 目标与边界

| 项 | 结论 |
|---|---|
| 协议 | 复用 Emby REST 语义，路径前缀 `/emby` |
| 客户端改动 | 0 行（只改服务器地址） |
| 服务根路径 | 客户端 `normalizeServerUrl` 会把末尾 `/emby` 剥掉，服务端必须自己加前缀 |
| 鉴权 | 同时支持 `X-Emby-Token` 请求头与 `api_key` 查询参数 |
| 播放方式 | 只需 DirectPlay 直链，**不实现转码** |
| 播放器 | Flutter `media_kit`(mpv) —— 对 HTTP Range 极其挑剔 |
| 时间单位 | Tick = 100ns，`RunTimeTicks = 微秒 × 10` |

播放器默认使用 `stream?static=true`，因此后端的第一优先级是把「文件直出 + Range」做对，
转码/HLS/DASH 可以完全不写。

## 2. 接口清单

### 2.1 认证与用户

| 方法 | 路径 | 请求 | 响应 |
|---|---|---|---|
| POST | `/Users/AuthenticateByName` | Header `X-Emby-Authorization`，Body `{"Username","Pw"}` | `{"User":{...},"AccessToken":"..."}` |
| GET | `/Users/{userId}/Images/Primary` | `api_key`,`MaxWidth`,`Quality`,`v` | JPEG |
| POST | `/Users/{userId}/Images/Primary` | Body 为 **Base64 字符串**（非 multipart），`Content-Type` 为真实 MIME | 204 |

登录失败语义（客户端据此提示文案）：
- `401` → 用户名或密码错误
- `403` → 该账号不允许登录

### 2.2 媒体库

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/Users/{userId}/Views` | 返回 `{Items:[{Id,Name,Type,CollectionType,...}]}` |
| POST | `/Library/Refresh` | 触发扫描，需管理员 |

### 2.3 条目查询

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/Users/{userId}/Items` | 主列表 + 搜索 + 人物作品，参数见下表 |
| GET | `/Users/{userId}/Items/Resume` | 继续观看，默认 `DatePlayed` 倒序 |
| GET | `/Users/{userId}/Items/{itemId}` | 详情 / 编辑页数据源 |
| GET | `/Persons` | 人物列表，`PremiereDate` 存生日 |
| GET | `/Items/{itemId}/Similar` | 相似推荐 |
| POST | `/Items/{itemId}` | 保存元数据 |
| POST | `/Items/{itemId}/Refresh` | 元数据刷新，需管理员 |

`/Users/{userId}/Items` 支持的查询参数：

```
Recursive, IncludeItemTypes, ParentId, Fields, EnableUserData, EnableImageTypes,
SortBy, SortOrder, StartIndex, Limit, Filters, VideoTypes, SearchTerm, Years, PersonIds
```

- `IncludeItemTypes` 实际用到：`Movie, Series, Video, Person, Episode`
- `Filters` 实际用到：`IsFavorite`
- `SortBy` 实际用到且需支持逗号多字段：`CommunityRating, Height, DateCreated,
  PremiereDate, DatePlayed, Runtime, SortName`
- `TotalRecordCount` 必须准确，否则分页 UI 失效

`Fields` 参数不是装饰，模型直接读取，必须能返回：

```
Overview, ProductionYear, PremiereDate, DateCreated, CommunityRating, RunTimeTicks,
Width, Height, Genres, Tags, Studios, People, MediaSources, Path, OfficialRating,
Chapters, BackdropImageTags, ScreenshotImageTags, ProviderIds, ExternalUrls, SortName,
BasicSyncInfo, CanDelete, CanDownload, PrimaryImageAspectRatio, Status, EndDate
```

> 简化策略：可以无视 `Fields` 一律返回全量字段，客户端会自行忽略多余字段。
> 代价是响应体积变大，不影响正确性。

### 2.4 图片

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/Items/{itemId}/Images/{type}[/{index}]` | type 用到 `Primary, Backdrop, Chapter, Screenshot` |
| GET | `/Items/{itemId}/Images` | 返回 `ImageType, ImageIndex, Filename, Width, Height` |
| POST | `/Items/{itemId}/Images/{type}[/{index}]` | Base64 body |
| DELETE | `/Items/{itemId}/Images/{type}/{index}` | |

必须真正按 `maxWidth` + `quality` 缩放。客户端海报位一次就要 1600px 宽的 Backdrop，
原图直出会让列表滚动直接卡死。

### 2.5 播放

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/Items/{itemId}/PlaybackInfo` | 返回 `MediaSources[]`，含完整 `MediaStreams` |
| GET | `/Videos/{itemId}/stream` | `static=true` + `mediaSourceId`，**必须支持 Range** |
| GET | `/Videos/{itemId}/index.bif` | 进度条缩略图 |
| POST | `/Sessions/Playing` | 起播 |
| POST | `/Sessions/Playing/Progress` | 每 10s 一次 |
| POST | `/Sessions/Playing/Stopped` | 停止，落播放进度 |

### 2.6 收藏

| 方法 | 路径 |
|---|---|
| POST / DELETE | `/Users/{userId}/FavoriteItems/{itemId}` |

响应需回 `{"IsFavorite": true/false}`。

## 3. 响应结构约束

客户端 `emby_pc_models.dart` 对字段名大小写敏感，以下为硬约束：

```jsonc
// 列表
{ "Items": [ /* BaseItemDto */ ], "TotalRecordCount": 123 }

// BaseItemDto 关键字段
{
  "Id": "...", "Name": "...", "SortName": "...", "Type": "Movie",
  "Overview": "...", "ProductionYear": 2023, "PremiereDate": "...",
  "DateCreated": "...", "CommunityRating": 8.1, "RunTimeTicks": 72000000000,
  "OfficialRating": "PG-13", "Width": 1920, "Height": 1080, "Path": "...",
  "Genres": [], "Tags": [], "Studios": [{"Id":"","Name":""}],
  "People": [{"Id":"","Name":"","Role":"","Type":"Actor","PrimaryImageTag":""}],
  "MediaSources": [ /* MediaSourceInfo */ ],
  "Chapters": [{"Name":"","StartPositionTicks":0,"ChapterIndex":0,"ImageTag":""}],
  "ProviderIds": {"Tmdb":"123"},
  "ExternalUrls": [{"Name":"","Url":""}],
  "ImageTags": {"Primary":"abc"},
  "BackdropImageTags": ["def"],
  "ScreenshotImageTags": [],
  "UserData": {
    "IsFavorite": false, "Played": false,
    "PlaybackPositionTicks": 0, "LastPlayedDate": "..."
  }
}
```

`UserData` 是「继续观看」「已看标记」「收藏红心」的唯一数据来源，不能省略。

## 4. 容易被忽略的隐形功能

真正的工作量不在 CRUD，而在这五块：

1. **媒体扫描入库**
   遍历目录 → 解析命名（`标题 (2023)` / `标题.2023.1080p.BluRay`）→ `ffprobe` 提取容器、
   编码、分辨率、时长、音轨、字幕轨 → 建立 库/条目/人物 关联。

2. **元数据来源（本方案不做刮削）**
   直接读取用户用 TMM / Emby / tinyMediaManager 预先生成的 NFO 与本地图片文件，
   后端只负责解析与落库，不访问任何外部元数据服务。因此不需要代理、不需要 API Key、
   也不存在网络失败导致的入库失败。

3. **图片派生**
   入库时生成 Primary / Backdrop / Thumb；章节图用 ffmpeg 抽帧；所有图按 `maxWidth` 实时缩放。

4. **BIF 缩略图生成**
   客户端解析规则（`emby_pc_player_page.dart` 的 `_BifPreviewData`）：
   - 文件头 64 字节
   - `bytes[1..3] == "BIF"`，`bytes[0] == 0x89`
   - 偏移 12：帧数（uint32 LE），偏移 16：时间戳乘数（ms，uint32 LE）
   - 从偏移 64 开始为索引表，每项 8 字节：`timestamp(uint32 LE) + offset(uint32 LE)`
   - 索引表共 **帧数 + 1** 项，最后一项仅提供数据区结束位置
   - 数据区为连续 JPEG

5. **权限模型**
   至少区分普通用户 / 管理员，`Library/Refresh`、`Items/{id}/Refresh`、
   `POST /Items/{id}`、图片上传删除都要拦。

## 5. 技术选型

关键约束：大文件 HTTP Range 流式传输、ffmpeg/ffprobe 子进程、图片缩放等 CPU 密集任务、
单机/家庭场景下部署要足够简单。

| 语言 | 开发速度 | 大文件流 | 媒体工具集成 | 部署 | 结论 |
|---|---|---|---|---|---|
| **Go** | 快 | 极好，`http.ServeContent` 原生 Range | 调子进程自然 | 单二进制 | **推荐** |
| Rust (axum) | 慢 | 极好 | 好 | 单二进制 | 性能党可选，周期翻倍 |
| Node/TS (Fastify/NestJS) | 最快 | 一般，需手写 Range | 一般，图片靠 sharp | 需 Node 运行时 | 原型备选 |
| Python (FastAPI) | 快 | 一般，易阻塞 | 最好 | 需 Python 环境 | 适合写刮削脚本 |
| C# ASP.NET Core | 中 | 好 | 好 | 需运行时 | 与 Emby 同源，语义最贴 |
| Java / Kotlin | 慢 | 好 | 好 | 偏重 | 不推荐 |

**选型结论：Go + 标准库 `net/http` + SQLite + 本地文件系统 + ffmpeg/ffprobe 子进程。**

理由：
- `http.ServeContent` 自带 `Range` / `206` / `Content-Range`，直接满足 mpv 的 seek 需求
- 交叉编译单文件，扔到 NAS 或 Windows 主机即可运行
- goroutine 处理多路并发拉流比单线程事件循环稳
- SQLite 用纯 Go 的 `modernc.org/sqlite`，Windows 上不需要 CGO

## 6. 实施路线

| 阶段 | 内容 | 里程碑 |
|---|---|---|
| P0 | 鉴权 + Views + Items 查询 + 详情 + 图片 + stream(Range) | 能登录、能浏览、能播放 |
| P1 | PlaybackInfo + 三条 Sessions 上报 + 收藏 + Resume | 进度记忆、继续观看 |
| P2 | 扫描器 + ffprobe + 命名解析 + 建库 | 自动入库 |
| P3 | 读取本地 NFO + 导入本地图片 | 海报、简介、演职人员 |
| P4 | BIF 生成 + 图片管理 + 元数据编辑/刷新 | 管理能力补齐 |

## 7. 兼容性坑位清单

1. `api_key` 查询参数鉴权必须实现 —— 图片和视频 URL 走的是 query，不是 header。
2. Range 响应必须严格：`Accept-Ranges: bytes`、`206 Partial Content`、正确的 `Content-Range`，
   否则拖动进度条直接失败或黑屏。
3. 图片上传 body 是 **Base64 纯文本**，不是 multipart/form-data。
4. `TotalRecordCount` 必须准确，否则前端分页永远只显示一页。
5. 时间一律 UTC ISO8601（`2023-05-01T00:00:00Z`），客户端负责转本地时区。
6. `EmbyPcItem.duration` 用 `RunTimeTicks ~/ 10` 得到微秒，单位不能错。
7. 客户端会带 `v=`（cacheKey）与 `quality=` 参数，服务端可以忽略，但不能报错。
8. `Type` 字段用于 UI 文案映射，必须是 `Movie` / `Series` / `Video` / `Person` / `Episode`。

## 8. 对应代码位置

| 关注点 | 文件 |
|---|---|
| 全部接口调用 | `emby_pc_service.dart` |
| 响应字段依赖 | `emby_pc_models.dart` |
| BIF 解析 | `emby_pc_player_page.dart` (`_BifPreviewData`) |
| 排序/过滤选项 | `emby_pc_workspace_toolbar.dart` |
| 后端骨架 | 仓库根目录 `server/` |
