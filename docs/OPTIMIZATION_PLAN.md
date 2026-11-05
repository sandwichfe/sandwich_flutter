# embyx 优化计划

后端 `server/`（Go + SQLite）+ 前端 `lib/pages/emby-pc/`（Flutter 桌面端）。

## 前置约定

- **不写数据迁移**：当前库里没有需要保留的数据。表结构变更直接改 `server/internal/store/schema.sql`，改完删除 `data/embyx.db` 重新扫描即可。
- 后端用一个 `schemaVersion` 常量做结构版本守卫：数据库版本与代码不一致时直接拒绝启动并提示删库，避免半旧半新的表结构跑出诡异结果。
- 当前 `schemaVersion = 3`（S1 增加 `fingerprint` / `nfo_mtime`，S3 增加 `item_people` / `person_view`）。**每次改表后递增版本号**。
- **不做电视剧**（Series / Season / Episode），也不做转码 / HLS。

> 已有的 `server/data/embyx.db` 是旧的 v0 结构，S0 加入版本守卫后会拒绝启动。
> 该文件已改名为 `embyx.db.v0.bak` 保留备份，首次启动会重建空库，随后在「设置 → 媒体库管理」重新添加目录并扫描即可。

## 实测结论（已跑过）

环境：modernc.org/sqlite，SQLite 3.46.0。

| 项 | 结果 | 对方案的影响 |
|---|---|---|
| FTS5 | 可用 | — |
| JSON1（`json_each` 等） | 可用（未列在 compile_options 里，但函数存在且正常） | 流派/标签聚合不必拆表 |
| FTS5 `trigram` 分词 | 可用，但**中文至少 3 字才命中**，2 字查询（`终局`）返回 0 | 中文搜索场景不可直接用 |
| FTS5 `unicode61` | 连续中文被当成单个 token，2 字查询不命中；逐字插空格后可命中 | 需要索引和查询两侧都做分字转换 |
| `LIKE '%x%'` 5000 行 | **1.07ms** | **FTS5 取消** |

结论：`FTS5 搜索`这一项从计划中移除。家用媒体库量级下 `LIKE` 的耗时远低于任何优化收益，而 FTS5 要额外维护虚拟表同步、中文分字转换、查询语义回归，属于净负担。等条目量到 5 万级再重新评估。

---

## 进度

| Sprint | 主题 | 状态 |
|---|---|---|
| S0 | 地基 | 已完成 |
| S1 | 条目身份与扫描增量 | 已完成 |
| S2 | 性能热点 | 已完成 |
| S3 | 查询能力与功能接口 | 已完成 |
| S4 | 运维与测试 | 已完成 |
| S5 | 前端 | 已完成（5.5 的 TTL 缓存层暂不做） |

---

## S0 地基

先做的理由：S2 排查「为什么这个接口慢」需要访问日志；后面三个 Sprint 都要改表结构，需要版本守卫兜底。

- [x] **0.1 schema 版本守卫**
  - `store/store.go` 删除历史包袱 `migrate()` / `tableColumns()`（只为兼容早期 `libraries` 列而存在）
  - 新增 `schemaVersion` 常量 + `PRAGMA user_version` 校验：全新库建表并写入版本；版本不一致直接报错提示删库
- [x] **0.2 访问日志中间件**
  - `httpapi/middleware.go` 新增 `withAccessLog`：`method path status 耗时 用户 响应字节`
  - 只打印 path，不打印 query（避免 `api_key` 进日志）
  - 耗时 ≥ 500ms 标记 `[慢请求]`
  - 图片/视频流在成功且不慢时不打日志，避免刷满日志文件
  - 中间件链调整为 `withRecover → withCORS → withAccessLog → withAuth → mux`
- [x] **0.3 错误响应改 JSON**
  - `httpapi/respond.go` 的 `writeError` 改为 `{"message": "...", "status": 401}`
  - 前端 `emby_pc_service.dart` 增加 `_responseError`，从 JSON 取 `message`，取不到退回原文（3 处内联错误体解析统一替换）
- [x] **0.4 根 context**
  - `cmd/embyx/main.go` 改用 `signal.NotifyContext`
  - 扫描、海报生成、BIF 预生成三类后台任务接受根 context，Ctrl+C 时先取消任务再关 HTTP
  - 验证：`Ctrl+C` 后日志出现取消，`tasklist | findstr ffmpeg` 无残留

**S0 验证方式**：`go build ./...` + `go vet ./...`；启动后 curl 一个列表接口与一个 401 接口，检查日志格式与 JSON 错误体。

---

## S1 条目身份与扫描增量（已完成）

### 1.1 扫描增量（fingerprint）

`schema.sql` 增加两列：

```sql
fingerprint TEXT NOT NULL DEFAULT '',   -- "size:mtimeNs"
nfo_mtime   INTEGER NOT NULL DEFAULT 0
```

改造 `media/scan.go:286-290`：`buildItem` 从「无条件 ffprobe」改为「先比指纹，命中则复用旧条目的探测结果，只更新路径与 NFO」。

| 验证 | 期望 |
|---|---|
| 全库第二次扫描 | ffprobe 调用数≈0，耗时降到 1/10 以内 |
| 改一个 NFO | 只有该条重新入库 |
| 覆盖同名视频文件 | 该条重新 ffprobe |

### 1.2 稳定 ID

`media/scan.go:294` 的 `sha1("item:" + 绝对路径)` 改为：

```
provider_ids.Tmdb → sha1("tmdb:" + id)
provider_ids.Imdb → sha1("imdb:" + id)
否则              → sha1("item:" + 相对库根的路径)
```

因为不做迁移，直接改完删库重扫。

| 验证 | 期望 |
|---|---|
| 改名一个视频文件后重扫 | 进度/收藏仍在（NFO 有 TMDB id 时） |
| 同一影片放 1080p/4K 两份 | 算出同一 ID，不重复建条目 |

### 1.3 陈旧条目清理

`scan.go:182-220` 补：条目删除时同步清理 `data/images/{id}` 与 `data/cache/bif/{id}-*.bif`。

### S1 落地结果

| 项 | 实现 |
|---|---|
| 指纹 | `items.fingerprint`（`size:mtimeNs`）+ `items.nfo_mtime`；命中即跳过 ffprobe 与图片导入，只 `UPDATE` 路径 |
| 稳定 ID | `deriveItemID`：TMDB → IMDb → 「库 ID + 相对库根路径（小写、正斜杠）」 |
| 清理 | 条目删除时同时删图片目录、BIF 缓存，并清 `user_data` / `play_sessions` |
| 测试 | `internal/media/scan_test.go`：ID 派生优先级、换盘/大小写不变性、指纹命中跳过探测、指纹变化重新探测 |

端到端实测（真实 ffprobe + 2 秒测试片 + 带 TMDB 编号的 NFO）：

| 场景 | 结果 |
|---|---|
| 首次扫描 | 1 条，ID 由 `tmdb:12345` 派生，标题取自 NFO |
| 重复扫描 | 新增入库日志 0 条（完全跳过 ffprobe） |
| 改名后扫描 | 新增入库日志 0 条，条目总数仍为 1，**ID 不变、收藏仍在**，路径已更新 |

---

## S2 性能热点（已完成）

### 2.1 数据库连接池

`store.go` 的 `SetMaxOpenConns(1)` 改为 `runtime.NumCPU()`（最小 2）。

`busy_timeout` / `synchronous` / `foreign_keys` 都是**每连接**的 PRAGMA，用 `Exec` 设置只影响当时那条连接，所以改为写进 DSN 由驱动逐连接应用：

```
file:<path>?_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(1)
```

`journal_mode=WAL` 是写进数据库文件的持久设置，仍然只执行一次。

### 2.2 列表查询收敛

| 项 | 落点 | 结论 |
|---|---|---|
| VirtualFolders N+1 | `library.go` | 已改为一条 `CountItemsByLibrary` 聚合 |
| `ORDER BY RANDOM()` | `items.go:193` | **不处理**：前端从未请求 `SortBy=Random`，属于未使用的路径 |
| COUNT + 列表两次查 | `items.go:141-158` | **不处理**：几千行规模下 `COUNT(*)` 实测 1ms 级，加 TTL 缓存反而引入失效问题 |

> 深分页改游标：**不做**。家用量级到不了 OFFSET 的痛点，且要连带改前端分页。

### 2.3 图片链路（已完成）

`media/imagecache.go` 新增 `ImageRenderer`，负责缓存、限流与请求合并：

| 项 | 实现 |
|---|---|
| 缓存 | `data/cache/images/{itemId}/{type}-{index}-{源图tag}-w{宽}-q{画质}.jpg` |
| 失效 | key 含源图内容标签，换图后旧文件自然不再命中，无需主动失效 |
| ETag | `"{源图tag}-w{宽}-q{画质}"` + `If-None-Match` → 304 |
| 并发 | `sem` 按 `runtime.NumCPU()` 限流；`flightGroup`（自实现 singleflight，不加依赖）合并同 key 请求 |
| 宽度上限 | 2000，超出按 2000 处理 |
| 缩放 | `resizeBilinear` 改为先把源图转 `*image.RGBA` 再按像素切片索引，权重改整数定点运算 |

实测（3000×2000 源图，`maxWidth=1600`）：

| 请求 | 耗时 | 大小 |
|---|---|---|
| 首次 | 113ms | 59,266B |
| 二次（命中缓存） | **12.8ms** | 59,266B |
| 带 `If-None-Match` | **304** | — |

### 2.4 BIF 异步（已完成）

`handleBif` 改为 `BifCache.EnsureAsync`：命中缓存直接返回文件；未命中只登记一次后台生成并立即返回 `202`（带 `Retry-After: 30`），播放器本轮降级成普通进度条。后台任务挂在服务根 context 上，进程退出会被取消。前端无需改动（`getBifPreview` 拿不到就返回 null）。

**顺带修掉一个会让 BIF 完全不可用的既有 bug**：ffmpeg 7 的 mjpeg 编码器拒绝非 full-range YUV。片长不足一个抽帧间隔时 `fps` 过滤器一帧都不输出，编码器仍按默认参数初始化并直接报错——于是「至少取首帧」的兜底逻辑根本执行不到，3 秒短片必然失败。修复方式是在主抽帧滤镜链末尾加 `format=yuvj420p`。

实测：首次请求 `202`（40ms 返回），**1 秒后**再次请求拿到 `200` 与 7,019B 的 BIF 文件。

---

## S3 查询能力与功能接口（已完成）

### 3.1 ~~FTS5 搜索~~（已取消，见实测结论）

### 3.2 人物拆表（已完成）

新增 `item_people` / `person_view` 两张表（`schemaVersion` 升到 3）。`items.people` 的 JSON 保留为展示用的权威数据，新表只是查询副本：

| 落点 | 实现 |
|---|---|
| 写入口 | `UpsertItem` 改为「条目 + 人物关联」同一事务，避免半写 |
| 关联行 | 同一人物可因 role/type 不同产生多行（导演 + 编剧），按 `person_id+type+role` 去重 |
| 作品数 | `person_view.item_count` 用 `COUNT(DISTINCT item_id)` 现算，不维护加减计数 |
| 头像 | `person_view.image_tag` 取 `People[].PrimaryImageTag`，空值不覆盖已有值 |
| 删除 | `DeleteItems` / `DeleteLibrary` 先删关联再删条目，作品数归零的人物一并回收 |
| `/Persons` | `person_view` 上 SQL 分页 + `name LIKE`，不再读全表 JSON、不再 Go 侧排序 |
| `PersonByID` | 主键查询，`ChildCount` 返回作品数 |
| `PersonIds` 过滤 | `EXISTS (SELECT 1 FROM item_people …)`，多个条件是 AND |

2000 部片子 / 700 位演职员的基准（`BenchmarkPersonsFromView`）：单页查询 **0.40ms**（旧实现要读 2000 行 JSON 再内存去重排序）。

### 3.3 流派 / 工作室 / 标签（已完成）

JSON1 可用，聚合直接用 `json_each`，不拆表：

```sql
SELECT je.value, COUNT(*) FROM items i, json_each(i.genres) je GROUP BY je.value;
```

| 路由 | 输出 |
|---|---|
| `GET /emby/Genres` | `{Id, Name, Type:"Genre", ChildCount}`，`Id` 就是名称 |
| `GET /emby/Tags` | 同上，`Type:"Tag"` |
| `GET /emby/Studios` | 按名称分组，`Id` 取条目里已有的 `StableID("studio:…")` |
| 公共参数 | `ParentId` 限定到某个媒体库 |

`ItemQuery` 新增：

| 参数 | SQL |
|---|---|
| `GenreIds` / `TagIds` | `EXISTS (SELECT 1 FROM json_each(i.genres|i.tags) je WHERE je.value IN (…))` |
| `StudioIds` | `json_extract(je.value,'$.Id') IN (…)` |
| `MinCommunityRating` | `COALESCE(i.community_rating,0) >= ?` |
| `Filters=IsPlayed/IsUnplayed/IsResumable` | 对应的 `user_data` 条件（`IsFavorite` 保持不变） |

流派与标签以**名称**为标识：库里本来就是字符串，没有独立主键。前端把浏览接口返回的 `Id` 原样回传即可；同一类目内多值为 OR，类目之间为 AND。

### 3.4 Items/Latest（已完成）

`GET /emby/Users/{id}/Items/Latest?Limit=&ParentId=&IncludeItemTypes=`

- 复用 `QueryItems`（`DateCreated DESC` + `i.id` 兜底稳定排序），`Limit` 默认 20、上限 100
- 返回**数组**（Emby 语义，不带 `TotalRecordCount`），`IncludeItemTypes` 缺省为 Movie/Series/Video/Episode

前端首页替换留在 S5.5（请求层会一起重做，避免同一块改两次），接口已可用。

### 3.5 扫描进度接口（已完成）

`GET /emby/Library/ScanStatus`（管理员）：

```json
{ "running": true, "libraryId": "...", "libraryName": "电影", "scanned": 120, "total": 500,
  "currentPath": "...", "failures": [{"path": "...", "reason": "..."}],
  "startedAt": "...", "finishedAt": "" }
```

| 项 | 实现 |
|---|---|
| 计数 | `media/scan_status.go` 一把互斥锁保护状态，worker 每处理完一个文件 `scanned++` |
| total | 目录遍历完先登记文件数，进度条一开始就有分母 |
| 多库 | `ScanAll` 累计计数，`libraryName` / `currentPath` 指向当前库与当前文件 |
| 失败 | `buildItem` / `UpsertItem` 的失败在 logf 之外同时进 `failures`，最多保留 200 条 |
| 结束 | `beginScan` 的 defer 写 `finishedAt`，`running` 转 false；未跑过扫描时全为默认值 |

前端 `library_admin.dart` 的「条目数稳定轮猜测」仍留在 S5.3 一起换。

### S3 落地结果

| 项 | 结果 |
|---|---|
| `go build ./...` / `go vet ./...` | OK |
| `go test ./...` | ok store / media / httpapi |
| 新增测试 | `store/persons_test.go`（人物分页/搜索/收藏、关联清理、分类聚合、新过滤条件）、`media/scan_status_test.go`（快照隔离与结束态）、`httpapi/s3_test.go`（Genres/Studios/Tags、GenreIds + Filters、Items/Latest、ScanStatus、匿名 401） |
| 基准 | `BenchmarkPersonsFromView`：0.40ms/页（2000 条目） |

改表后必须删 `data/embyx.db` 重扫，版本守卫会拦下旧库。

---

## S4 运维与测试（已完成）

### 4.1 缓存回收

`media/cachegc.go` 新增 `CacheJanitor`，回收两类垃圾：

| 对象 | 策略 |
|---|---|
| `data/cache/images/{id}/` | 删 ID 不在库里的目录（条目 + 人物 `person_view`）；超上限按目录整体 LRU 淘汰 |
| `data/cache/bif/*.bif` | 删 ID 不存在、或片源 mtime 已新于缓存的文件；超上限按旧到新淘汰 |

| 项 | 实现 |
|---|---|
| 归属来源 | `store.CacheOwners` 一次查出 `items.id → path` 与 `person_view.person_id`（演员头像与条目共用缓存目录） |
| LRU 依据 | `ImageRenderer` 内存里记最近渲染时间（`LastAccess`），进程重启后回落到目录 mtime |
| 触发 | 启动先扫一轮，之后按 `cache.sweep_interval` 定时；条目删除时通过 `Scanner.SetItemRemovedHook` 立即清 |
| 配置 | `cache.image_limit_mb`（默认 2048）、`cache.bif_limit_mb`（默认 1024）、`cache.sweep_interval`（默认 6h）；上限写 0 表示不按容量淘汰 |

### 4.2 单元测试

| 文件 | 测点 | 状态 |
|---|---|---|
| `store/items_test.go` | ItemQuery 参数组合、排序白名单（含注入尝试）、分页边界 | 已完成 |
| `store/store_test.go` | DSN PRAGMA 生效、版本守卫、并发读 | 已完成 |
| `store/persons_test.go` | 人物分页/搜索/收藏、关联清理、分类聚合、新增过滤条件 | 已完成（S3） |
| `media/scan_test.go` | ID 派生、指纹命中/变化 | 已完成 |
| `media/imagecache_test.go` | 缓存命中、标签随源图变化、缩放数值 | 已完成 |
| `media/cachegc_test.go` | 孤儿清理、LRU 淘汰、片源更新的 BIF 判定、按条目清理 | 已完成 |
| `media/scan_status_test.go` | 扫描进度快照与结束态 | 已完成（S3） |
| `media/bif_test.go` | 打包→解析回环、跨参数复用、陈旧判定、早期文件改名、按前缀清理 | 已完成 |
| `media/probe_test.go` | `testdata/*.json` 样本测流信息映射（`parseProbeOutput` 与子进程分离，不依赖 ffprobe） | 已完成 |
| `httpapi/s3_test.go` | Genres/Studios/Tags、GenreIds + Filters、Items/Latest、ScanStatus 路由 | 已完成（S3） |
| `httpapi/auth_test.go` | 鉴权矩阵：公开路由 / 未登录 / 伪造令牌 / 四种令牌来源 / 普通用户 403 / 管理员 200 / 注销后失效 | 已完成 |

### 4.3 日志轮转

`main.go` 的日志写入改为 `rotatingWriter`：每次写入前检查大小，超过 5MB 就把当前文件改名为 `.old` 并重开，旧文件只留一份。不再依赖启动时判断，长期运行不会无限增长。

### S4 落地结果

| 项 | 结果 |
|---|---|
| `go build ./...` / `go vet ./...` | OK |
| `go test ./...` | ok store / media / httpapi |
| 新增文件 | `store/cache.go`、`media/cachegc.go`、`media/cachegc_test.go`、`store/items_test.go`、`media/bif_test.go`、`media/probe_test.go`、`media/testdata/*.json`、`httpapi/auth_test.go` |

> 测试中发现并据实修正的两处预期：`GET /Library/VirtualFolders` 本来就不要求管理员（侧栏渲染要用），`BifCache.Lookup` 的参数顺序是 `(intervalMs, width)`，与 `Path` 的 `(width, intervalMs)` 相反。

---

## S5 前端（进行中）

| # | 任务 | 落点 | 状态 |
|---|---|---|---|
| 5.1 | 请求层：单例 `http.Client` + 15s timeout + 401 集中拦截 + 修「首个请求失败即 logout」 | `emby_pc_service.dart`、`emby_pc_page.dart` | 已完成 |
| 5.2 | 服务器地址设置项，去掉硬编码 `localhost:8096` | `settings_page.dart`、`service`、`login` | 已完成 |
| 5.3 | 扫描进度改读 `/Library/ScanStatus` | `library_admin.dart` | 已完成 |
| 5.4 | 全局搜索（限 60）、人物作品（限 100）补分页 | `service`、`global_search`、`person_page` | 已完成 |
| 5.5 | 工作台拆分（状态与数据加载抽到 controller）；Repository 层 TTL 缓存暂缓 | `emby_pc_page.dart`、`emby_pc_workspace_controller.dart` | 拆分已完成 / 缓存未做 |
| 5.6 | 筛选栏接 S3 的流派/年份/评分/演员 | `workspace_toolbar.dart`、`service`、`page` | 已完成 |
| 5.7 | 播放器：倍速、音轨/字幕轨切换、设置持久化 | `emby_pc_player_page.dart` | 已完成 |
| 5.8 | 图片 URL 带 `v={tag}`，配合 2.3 的缓存失效 | `service`、各图片调用点 | 已完成 |

### S5 已完成部分落地结果

| 项 | 实现 |
|---|---|
| 请求层 | 单例 `_client`（`_TimeoutClient` 包一层 `http.Client`，15s 超时 → 中文提示）；`http.get/post/put/delete` 全部改走它，连接可复用 |
| 401 拦截 | `_ensureSuccess` / `_decodeResponse` 遇到 401 调 `_notifyUnauthorized()`：清会话 + `unauthorizedRevision` 自增；工作台监听后回登录页，多个并发请求只清一次 |
| 403 | 与 401 拆开，提示「当前账号没有管理权限」，不再误报登录失效 |
| 首次请求失败 | `_initialize` 只在 `isLoggedIn == false` 时回登录页，网络错误改为展示可重试的错误页 |
| 服务器地址 | 设置页「账户 → 服务器地址」弹窗修改；保存后 `updateServerUrl` 落盘并注销会话，返回工作台自动回登录页；`readSavedLogin` 不再回落 `localhost:8096` |
| 扫描进度 | 轮询 `/Library/ScanStatus`（2s），横幅显示 `已扫描/总数`、当前文件、失败数；连续两次 `running=false` 才判定结束，避开刚触发时的空档，结束后自动刷新条目数 |
| 分页 | `searchItems`/`getPersonItems` 支持 `startIndex`；搜索浮层与人物作品页各加「加载更多」，按 id 去重 |
| 图片 tag | 新增 `imageUrlForItem` / `imageUrlForPerson`，从 `ImageTags`/`BackdropImageTags`/`PrimaryImageTag` 取 `v`；列表、详情、搜索、人物卡片全部改用它 |
| 筛选栏（5.6） | 筛选面板新增「流派」（`/Genres` 按当前库懒加载 + 缓存，取条目数前 12）、「最低评分」（7/8/9 分以上）、「演员」（关键词查 `/Persons` 后选人，走 `PersonIds`）；`getItems` 增加 `genreIds`/`personIds`/`minCommunityRating`；切库/切视图时 `_resetQueryControllers` 一并清空 |
| 播放器（5.7） | 控制栏新增倍速菜单（0.5~2.0）；音轨菜单（>1 条才出现）、字幕菜单（含「关闭字幕」）订阅 `player.stream.tracks/track` 自更新；音量与倍速写入 `SharedPreferences`（音量退出时落盘、倍速改完即存），`PlaybackRate` 按实际倍速上报 |
| 工作台拆分（5.5） | 新增 `EmbyPcWorkspaceController`（`ChangeNotifier`）：媒体库、列表、首页摘要、侧栏计数、筛选条件、分页状态与全部加载方法（`initialize`/`loadHome`/`loadItems`/`loadCounts`/`ensureGenreOptions`/`searchPersons`/`applyQuery`）集中在此；页面只留文本与滚动控制器、Busy 集合、防抖定时器，以及依赖 `context` 的弹窗/提示/导航。`emby_pc_page.dart` 从 1037 行降到 716 行 |

验证：`dart analyze`（IDE 诊断）无 error、无新增 warning；后端 `go test ./...` 全部通过。

---

## 风险

| 风险 | 应对 |
|---|---|
| 改 schema 后旧库不可用 | `schemaVersion` 守卫在启动时报错提示删库，不静默跑坏 |
| 前后端错误体格式联动 | 0.3 与前端 `_responseError` 同批上线 |
| 图片缓存与换图不一致 | 缓存 key 含源 tag，写操作按 itemId 前缀清缓存 |
| BIF 异步后首次播放无预览 | 可接受；用缩略图预生成页提前跑 |
