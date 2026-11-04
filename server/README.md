# embyx

Emby 协议兼容的轻量媒体服务器骨架，目标是替换现有 Flutter 客户端（`lib/pages/emby-pc`）所依赖的 Emby Server，客户端零改动。

接口契约与调研结论见 `../lib/pages/emby-pc/backend_design.md`。

## 已完成（P0 / P1 骨架）

- 认证：`POST /emby/Users/AuthenticateByName`，令牌同时支持 `X-Emby-Token` 头与 `api_key` 参数
- 媒体库：`GET /Users/{id}/Views`、`GET/POST /Library/VirtualFolders`、`PUT /Library/VirtualFolders/{id}`、`POST /Library/VirtualFolders/Name`、`DELETE /Library/VirtualFolders`、`POST /Library/Refresh`（异步扫描）
- 条目：`/Users/{id}/Items`（过滤/搜索/排序/分页）、`/Items/Resume`、`/Users/{id}/Items/{id}`、`/Persons`、`/Items/{id}/Similar`
- 图片：条目图片 GET/上传/删除/列表，用户头像 GET/上传，按 `maxWidth` + `quality` 缩放
- 播放：`POST /Items/{id}/PlaybackInfo`、`GET /Videos/{id}/stream`（完整 Range 支持）、`GET /Videos/{id}/index.bif`
- 缩略图预生成：`POST /emby/ThumbnailJobs`（按媒体库批量生成，可指定抽帧间隔/宽度，默认复用已有缓存，传 `Force: true` 强制重建）、`GET /emby/ThumbnailJobs`、`GET /emby/ThumbnailJobs/{jobId}`、`POST /emby/ThumbnailJobs/{jobId}/Cancel`
- 进度：`POST /Sessions/Playing`、`/Playing/Progress`、`/Playing/Stopped`
- 收藏：`POST/DELETE /Users/{id}/FavoriteItems/{id}`
- 扫描：遍历媒体目录 → `ffprobe` 提取技术信息 → 读取 NFO 元数据 → 导入本地图片 → 入库

**不内置刮削**。元数据完全来自你自己刮好的 NFO 和本地图片文件。

## 待实现

- 剧集结构：Season / Episode 层级，Series 详情页
- `VideoTypes` 过滤、FTS 全文搜索（中文需拼音化）
- 图片缩放换成 libvips（当前为纯 Go 双线性）
- 多用户管理、权限细分

## NFO 与本地图片

只读取，不联网。按 Kodi / Emby / tinyMediaManager 的通用约定。

### NFO 查找顺序

1. `<视频名>.nfo`（如 `阿凡达 (2009).nfo`）
2. 同目录 `movie.nfo`

支持 UTF-8（含 BOM）。解析失败的 NFO 会记录日志并回退到文件名推断。

### NFO 字段映射

| NFO | 落库字段 |
|---|---|
| `title` / `sorttitle` | `Name` / `SortName` |
| `plot`（`outline` 兜底） | `Overview` |
| `year` / `premiered` / `dateadded` | `ProductionYear` / `PremiereDate` / `DateCreated` |
| `mpaa` | `OfficialRating` |
| `rating` 或 `ratings/rating/value` | `CommunityRating` |
| `genre` / `tag` / `studio` | `Genres` / `Tags` / `Studios` |
| `uniqueid type="tmdb\|imdb\|tvdb"` | `ProviderIds` |
| `director` / `credits` / `actor` | `People`（Director / Writer / Actor） |
| `runtime` | 仅当 ffprobe 未拿到时长时兜底 |

演员的人物 ID 由姓名派生（`sha1("person:"+姓名)`），同一演员在不同影片中聚合为同一个条目。

### 图片命名

优先级从左到右：

| 用途 | 文件名 |
|---|---|
| 海报 | `<视频名>-poster` > `poster` > `folder` > `cover` > `<视频名>` > `movie` |
| 背景图 | `<视频名>-fanart` > `fanart` > `<视频名>-backdrop` > `backdrop` > `background`，另支持 `fanart1..10` / `backdrop1..10` |
| 横幅 | `<视频名>-banner` > `banner` |
| 缩略图 | `<视频名>-thumb` > `thumb` > `landscape` |
| Logo | `<视频名>-clearlogo` > `clearlogo` > `<视频名>-logo` > `logo` |
| 演职员头像 | `.actors/<演员名>.jpg` |

支持 `.jpg` / `.jpeg` / `.png`（`.webp` 会被跳过）。图片导入是幂等的：目标文件比源文件新时直接复用，不会每次扫描都重新转码。

### 进度条缩略图（BIF）

媒体目录里已有预生成的 BIF 时直接复用，不再调用 ffmpeg 抽帧：

- `<视频名>.bif`
- `<视频名>-<宽>-<间隔>.bif`，例如 `IPX712.[4K]-320-10.bif`

没有才会现场生成，结果缓存在 `data/cache/bif/{itemId}-w{宽}-i{间隔毫秒}.bif`。
文件名带参数，"是否已生成"直接由磁盘回答：参数不变时预生成任务默认复用（换参数、片源更新或手动删文件才会重新抽帧）。

### 典型目录

```
电影/
└── 阿凡达 (2009)/
    ├── 阿凡达 (2009).mp4
    ├── movie.nfo
    ├── poster.jpg
    ├── fanart.jpg
    └── .actors/
        └── 萨姆·沃辛顿.jpg
```

## 环境要求

- Go 1.22+
- `ffmpeg` / `ffprobe`（已在 PATH，或通过环境变量指定）

依赖只有 `modernc.org/sqlite`（纯 Go，Windows 无需 CGO）。

## 构建与运行

```powershell
cd server
go mod tidy
go build -o embyx.exe ./cmd/embyx
.\embyx.exe
```

首次启动如果按上面的规则都没找到 `config.yaml`，且**工作目录就是程序目录**（双击运行），会自动生成一份模板；
其他情况（IDE 调试、工作目录不在程序目录）以及显式用 `-config` / `EMBYX_CONFIG` 指定但文件不存在时，
都会直接报错并提示实际的工作目录与程序目录，避免在错误目录里凭空生成一份配置。
改完配置重启即可生效。客户端服务器地址填 `http://<host>:8096`。

## 配置文件

`config.yaml`，可用 `-config <路径>` 或环境变量 `EMBYX_CONFIG` 指定其他位置。
未指定时先在当前工作目录找，找不到会逐级向上查找；启动日志会打印实际使用的配置**绝对路径**。

```yaml
server:
  addr: ":8096"          # 监听地址，":8096" 表示所有网卡
  data_dir: "./data"     # 数据库 / 图片 / 缓存目录，相对路径基于配置文件所在目录

account:
  admin_user: admin
  admin_password: admin  # 仅在首次创建账号时使用

ffmpeg:
  ffprobe: ffprobe       # 不在 PATH 时写绝对路径
  ffmpeg: ffmpeg
```

媒体库不再写在配置文件里，改由客户端「设置 → 媒体库管理」维护（`Library/VirtualFolders` 接口），
启动时也不会自动扫描，需要在设置页点扫描或调用 `POST /Library/Refresh`。

路径写法（`ffmpeg`、`data_dir` 等路径字段同理）：

| 写法 | 示例 | 说明 |
|---|---|---|
| 单引号（推荐） | `ffprobe: 'D:\ffmpeg\bin\ffprobe.exe'` | 反斜杠原样保留 |
| 正斜杠 | `ffprobe: "D:/ffmpeg/bin/ffprobe.exe"` | 跨平台写法 |
| 双引号 + 反斜杠 | `ffprobe: "D:\ffmpeg\bin\ffprobe.exe"` | 报 `unknown escape character` |

双引号里的反斜杠会被 YAML 当成转义符，这是最常见的启动失败原因。

配置文件解析失败时程序会退出，详细错误（含行号）同时写入 exe 同目录的 `embyx.log`。

支持 UNC 网络路径（`\\server\share\...`），前提是当前 Windows 用户已有该共享的访问权限。
网络盘扫描速度受带宽限制，`ffprobe` 需要读取文件头部，建议先在小目录验证。

配置优先级：**环境变量 > 配置文件 > 内置默认值**。

## 环境变量（覆盖配置文件）

| 变量 | 说明 |
|---|---|
| `EMBYX_CONFIG` | 配置文件路径，默认 `./config.yaml` |
| `EMBYX_ADDR` | 监听地址 |
| `EMBYX_DATA_DIR` | 数据目录 |
| `EMBYX_ADMIN_USER` / `EMBYX_ADMIN_PASSWORD` | 管理员账号 |
| `EMBYX_FFPROBE` / `EMBYX_FFMPEG` | ffmpeg 工具路径 |

## 目录结构

```
server/
├── cmd/embyx/main.go          启动、依赖装配、优雅关闭
├── internal/
│   ├── config/                环境变量配置
│   ├── dto/                   与 Emby 协议对齐的 JSON 结构（字段名不可改）
│   ├── httpapi/               路由、中间件、各接口处理器
│   ├── media/                 ffprobe 探测、图片缩放、BIF 打包、目录扫描
│   └── store/                 SQLite 存储（users / items / user_data / libraries）
└── data/                      运行时生成
    ├── embyx.db
    ├── images/{itemId}/{type}/{index}.jpg
    ├── users/{userId}/primary.jpg
    └── cache/bif/{itemId}-w{宽}-i{间隔毫秒}.bif
```

## 数据目录说明

```
GET  /emby/Users/{id}/Views
GET  /emby/Users/{id}/Items?Recursive=true&IncludeItemTypes=Movie,Series,Video&...
GET  /emby/Users/{id}/Items/Resume
GET  /emby/Users/{id}/Items/{itemId}
POST /emby/Items/{itemId}/PlaybackInfo
GET  /emby/Videos/{itemId}/stream?static=true
POST /emby/Sessions/Playing|Progress|Stopped
```

## 已知限制

- 未实现转码，只支持 DirectPlay；容器/编码不被播放器支持时会直接失败
- 扫描器目前把所有条目按 `Movie` 入库，剧集识别待补
- 条目图片需要手工上传，自动刮削图片尚未接入
