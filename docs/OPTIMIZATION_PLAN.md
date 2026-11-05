# embyx 优化计划

后端 `server/`（Go + SQLite）+ 前端 `lib/pages/emby-pc/`（Flutter 桌面端）。

## 前置约定

- **不写数据迁移**：当前库里没有需要保留的数据。表结构变更直接改 `server/internal/store/schema.sql`，改完删除 `data/embyx.db` 重新扫描即可。
- 后端用一个 `schemaVersion` 常量做结构版本守卫：数据库版本与代码不一致时直接拒绝启动并提示删库，避免半旧半新的表结构跑出诡异结果。
- 当前 `schemaVersion = 2`（S1 为 `items` 增加了 `fingerprint` / `nfo_mtime`）。**每次改表后递增版本号**。
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
| S3 | 查询能力与功能接口 | 未开始 |
| S4 | 运维与测试 | 未开始 |
| S5 | 前端 | 未开始 |

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

## S3 查询能力与功能接口

### 3.1 ~~FTS5 搜索~~（已取消，见实测结论）

### 3.2 人物拆表

```sql
CREATE TABLE item_people(
    item_id TEXT NOT NULL,
    person_id TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT '',
    type TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_item_people_item   ON item_people(item_id);
CREATE INDEX idx_item_people_person ON item_people(person_id);

CREATE TABLE person_view(
    person_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    image_tag TEXT NOT NULL DEFAULT '',
    item_count INTEGER NOT NULL DEFAULT 0
);
```

替换点：

| 现状 | 新实现 |
|---|---|
| `/Persons` 全表读 `people` JSON + Go 内存排序分页（`persons.go:43-98`） | SQL 分页查 `person_view` |
| `PersonByID` 用 `LIKE '%"Id":"x"%'`（`persons.go:101`） | 主键查 |
| `PersonIds` 过滤用 JSON 子串（`items.go:125-129`） | `JOIN item_people` |

写入口：扫描入库时同步写 `item_people` 与 `person_view`。

验证：造 2000 条数据，`/Persons` < 100ms；按演员筛作品结果与原实现一致。

### 3.3 流派 / 工作室 / 标签浏览与过滤

JSON1 可用，聚合直接用 `json_each`，不拆表：

```sql
SELECT je.value, COUNT(*) FROM items, json_each(items.genres) je GROUP BY je.value;
```

新增路由 + `ItemQuery` 参数：

| 路由 | 说明 |
|---|---|
| `GET /emby/Genres` | 名称 + 条目数 |
| `GET /emby/Studios` | 同上 |
| `GET /emby/Tags` | 同上 |

`ItemQuery` 补 `GenreIds`、`TagIds`、`StudioIds`、`MinCommunityRating`、`IsPlayed`、`IsUnplayed`、`IsResumable`。

### 3.4 Items/Latest

`GET /emby/Users/{id}/Items/Latest?Limit=&ParentId=` → `ORDER BY date_created DESC` + UserData 关联。前端首页改用它替代「每库拉 10 条」。

### 3.5 扫描进度接口

`GET /emby/Library/ScanStatus`（管理员）：

```json
{ "running": true, "libraryId": "...", "scanned": 120, "total": 500,
  "currentPath": "...", "failures": [{"path": "...", "reason": "..."}],
  "startedAt": "...", "finishedAt": null }
```

scanner 内部维护原子计数 + 互斥的 failures 列表；`scan.go:258-262` 的「只 logf」改为同时进 failures。

前端 `library_admin.dart:286-332` 的「条目数稳定轮猜测」删除，换此接口。

---

## S4 运维与测试

### 4.1 缓存回收

| 对象 | 策略 |
|---|---|
| `data/cache/images/*` | 删 itemId 不存在的目录；目录级 LRU |
| `data/cache/bif/*` | 删 itemId 不存在或源文件已更新的文件；总量超阈值按旧到新淘汰 |

触发：定时任务 + `purgeMissingItems` 时同步删。

### 4.2 单元测试

| 文件 | 测点 | 状态 |
|---|---|---|
| `store/items_test.go` | 内存 SQLite，测 ItemQuery 参数组合、排序白名单、分页边界 | 待补 |
| `store/store_test.go` | DSN PRAGMA 生效、版本守卫、并发读 | 已完成 |
| `media/scan_test.go` | ID 派生、指纹命中/变化 | 已完成 |
| `media/imagecache_test.go` | 缓存命中、标签随源图变化、缩放数值 | 已完成 |
| `media/bif_test.go` | 打包→解析回环、跨参数复用、陈旧判定 | 待补 |
| `media/probe_test.go` | 用 `testdata/*.json` 样本测流信息映射（不依赖真 ffprobe） | 待补 |
| `httpapi/auth_test.go` | httptest 跑鉴权矩阵：未登录 / 普通用户 / 管理员 × 各路由 | 待补 |

### 4.3 日志轮转

`main.go:103` 只在启动时滚动一次 5MB，长期运行会无限增长。改为按大小定时轮转。

---

## S5 前端

| # | 任务 | 落点 |
|---|---|---|
| 5.1 | 请求层：单例 `http.Client` + 15s timeout + 401 集中拦截 + 修「首个请求失败即 logout」 | `emby_pc_service.dart:867-906`、`emby_pc_page.dart:200-207` |
| 5.2 | 服务器地址设置项，去掉硬编码 `localhost:8096` | `service:50`、`login:126`、`settings_page.dart` |
| 5.3 | 扫描进度改读 `/Library/ScanStatus` | `library_admin.dart:286-332` |
| 5.4 | 全局搜索（限 60）、人物作品（限 100）补分页 | `service:537`、`service:648-668` |
| 5.5 | 工作台拆分 + Repository 层 TTL 缓存，消掉启动 2N+3 请求与返回全量重拉 | `emby_pc_page.dart` + 5 个 part |
| 5.6 | 筛选栏接 S3 的流派/年份/评分/演员 | `workspace_toolbar.dart` |
| 5.7 | 播放器：倍速、音轨/字幕轨切换、设置持久化 | `emby_pc_player_page.dart:131-136` |
| 5.8 | 图片 URL 带 `v={tag}`，配合 2.3 的缓存失效 | `service:693-760` |

---

## 风险

| 风险 | 应对 |
|---|---|
| 改 schema 后旧库不可用 | `schemaVersion` 守卫在启动时报错提示删库，不静默跑坏 |
| 前后端错误体格式联动 | 0.3 与前端 `_responseError` 同批上线 |
| 图片缓存与换图不一致 | 缓存 key 含源 tag，写操作按 itemId 前缀清缓存 |
| BIF 异步后首次播放无预览 | 可接受；用缩略图预生成页提前跑 |
