# embyx 后端代码评审

分析范围：`cmd/embyx/main.go` 与 `internal/`（config / dto / httpapi / media / store，共 49 个 Go 文件）。
评审时间：2026-11-05。

整体质量高于一般个人项目：依赖注入清晰、`context` 贯穿全链路、注释写的是"为什么"而不是"是什么"，
幂等扫描、文件指纹、原子写、LRU 缓存回收这些工程细节都做到了位。下面按
**该修的（功能/正确性）→ 该优化的（性能）→ 该收的（代码质量）** 排列。

---

## 处理进度

修复计划按「改动影响面」分批推进，每批改完立即自检；下面勾选项随提交同步更新。

| 批次 | 事项 | 状态 |
|---|---|---|
| A | 一.1 BIF 超时显式化、一.6 后台 goroutine recover、一.7 密码不进日志、一.2 删库清 BIF、一.3 `bif-*` 残留清理 | ✅ 已完成 |
| B | 二.1 列表瘦身、二.2 轻量查询、二.3 SkipTotal、二.7 `ReadFrom`、二.8 头像走渲染缓存、二.9 热点、二.10 索引 | ✅ 已完成 |
| C | 一.4 token TTL + 登出 + 清理、一.5 `play_sessions` 过期、一.8 BIF 间隔参数 | ✅ 已完成 |
| D | 二.5 扫描一次性读索引 + 目录快照、二.6 批量删除、三.2 `keyedMutex`、三.3~三.7 杂项、三.8 测试 | ✅ 已完成 |
| E | 三.1 两套 job manager 泛型化 | ⏸ 暂缓（纯整洁项，改动面覆盖两个任务状态的并发路径，收益低于回归风险；后续单独重构） |

### 第 A 批（功能正确性 / 稳定性）

1. `BifOptions` 新增 `Timeout`，由调用方显式决定（播放侧 10 分钟、预生成 60 分钟），不再借用 `force`。
2. 新增 `media.RunSafe`，后台 goroutine 统一兜 panic；两个任务管理器的 `run` 也各自回收 panic 并把任务标记为取消，避免任务永远停在 running。
3. 默认管理员密码不再写进日志，仅在仍是内置默认值时提示尽快修改。
4. 删除媒体库时按前缀批量清理 BIF 缓存（`BifCache.RemoveItems`，只枚举一次目录）。
5. 缓存巡检删除残留的 `bif-*` 临时目录（进程被强杀时 `defer os.RemoveAll` 不会执行）。

### 第 B 批（性能）

1. `ItemQuery` 新增 `Detail` / `SkipTotal`：列表默认只输出卡片字段（不再带 `People`/`Chapters`/`MediaSources`），显式请求 `Fields` 时才回退完整形态；`Latest` 不再白跑一次 `COUNT(*)`。
2. 播放与 BIF 只取 `Path` 的地方改用 `store.ItemSource`（5 列，不再反序列化 11 个 JSON 字段）。
3. `statusRecorder` 透传 `io.ReaderFrom`，`http.ServeContent` 恢复零拷贝。
4. 用户头像改走 `ImageRenderer`，顺带获得磁盘缓存、singleflight、ETag。
5. 热点：`applyVignette` 去掉 92 万次 `sqrt`；`BifCache.anyVariant` 加短 TTL 目录快照；流派/标签/工作室聚合加短 TTL 内存缓存。
6. 补 `items(library_id, date_created)` 与 `user_data(user_id, played, last_played_date)` 索引。

### 第 C 批（安全 / 数据增长）

1. `token_ttl` 真正生效：查询令牌时校验签发时间；新增 `POST /emby/Sessions/Logout`；登录时顺带清理该用户已过期的令牌。
2. `play_sessions` 定期清理超过 1 小时没有上报的会话。
3. `index.bif` 支持 `IntervalMs` 参数，缺省仍是 10 秒。

### 第 D 批（扫描性能 / 代码质量）

1. 扫描开始时一次性读入条目指纹，`buildItem` 不再每文件查一次库；路径没变时也不再逐条 `UPDATE`。
2. 扫描期间按目录缓存文件快照，海报/演员头像不再对同一目录重复 `ReadDir`。
3. `DeleteItems` / `deleteItemPeople` 改为 `IN (...)` 批量删除。
4. 抽取 `keyedMutex` 替换三份「按 key 加锁」实现，锁表用引用计数回收。
5. `Prober` 只构造一次；`normalizeImageType` 合并到 `media` 一份；`imageType` 走白名单清洗；`getRawItem` 不再用 `ud.user_id = ''` 凑列数。
6. `prepareSchema` 引入按 `user_version` 递增的迁移，新增索引不再要求删库。
7. 补 `httpapi` 的参数解析与令牌来源表驱动测试。

### 实施说明与遗留项

- **一.8 已确认不需要改客户端**：`emby_pc_player_page.dart` 的 `_BifPreviewData.parse` 按索引表里的
  时间戳（绝对毫秒）二分查找，不按「帧序号 × 头间隔」推算，所以播放侧复用其它间隔的变体不会错位。
  服务端仍补了 `IntervalMs` 参数，便于将来精确命中。
- **二.3 只对 `Latest` 生效**：翻页（`StartIndex > 0`）时仍照常统计 total，因为客户端用
  `TotalRecordCount` 判断是否还有下一页，返回 0 会让分页提前结束。
- **二.4 令牌查询缓存**：`Store.UserByToken` 增加了 1 分钟缓存，登出/清理过期令牌时主动失效；
  缓存条目的过期时刻不会晚于令牌自身的过期时刻。
- **二.5 的第二项（扫描一次性读索引）已做**：`purgeMissingItems` 仍保留一次 `LibraryItemRefs` 查询
  （单条 SQL），但逐条 `os.Stat` 改为按 worker 数并发。
- **三.1 暂缓**：两套 job manager 的泛型化是纯整洁项，涉及任务状态并发路径与两套错误值，
  收益低于回归风险。若要推进，建议单独一轮重构并补 `media` 包的并发测试。
- 全部改动通过 `go vet`、`go test ./...` 与 `go test -race ./internal/...`。

---

## 一、功能层面（建议优先处理）

### 1. BIF 预生成超时判断用错了变量（实际会失败）

```go
// internal/media/bif.go:310
// 抽帧需要解码整部影片：预生成遇到 4K/网络盘长片往往超过 10 分钟，
// 所以只在播放侧保留短超时，预生成放宽到 60 分钟。
timeout := 10 * time.Minute
if force {
    timeout = 60 * time.Minute
}
```

注释说的是"预生成 60 分钟"，但代码判的是 `force`。而 `ThumbnailJobManager` 调用时
`Force` 默认 `false`（设置页不勾"强制重新生成"就是 false），于是**最典型的整库预生成走的是
10 分钟超时**。一部 4K 两小时片，`fps=1/10` 需要解码全片，网络盘上很容易超时。

建议：给 `BifOptions` 加显式字段 `Timeout time.Duration`（或 `Background bool`），
由调用方决定，不要复用 `force`。

### 2. 删除媒体库不回收 BIF 缓存

```go
// internal/httpapi/library.go:268
for _, itemID := range itemIDs {
    _ = s.images.RemoveItem(itemID)
    s.imageRenderer.RemoveItem(itemID)
}
```

扫描清理陈旧条目时走的是 `removeCachedBif`（`scan.go:262`），删库这条路漏了。
删掉一个几千条的库，`cache/bif` 下会残留几千个 `.bif` 直到下一轮 6 小时巡检。

### 3. `bif-*` 临时目录永远不会被清理

`Generate` 用 `os.MkdirTemp(c.dir, "bif-*")`（`bif.go:304`）在缓存目录里建临时目录，
依赖 `defer os.RemoveAll`。进程被强杀（任务管理器结束、断电）就留下一个，
而 `sweepBif` 明确跳过目录：

```go
// internal/media/cachegc.go:199
if entry.IsDir() {
    continue
}
```

建议：`sweepBif` 里对 `bif-*` 目录按 mtime 超过 N 小时直接删除，或在 `BifCache` 启动时清一次。

### 4. token 永不过期 + 无登出 + tokens 表只增

`cfg.TokenTTL` 加载了但**从未被读取**（全仓无第二处使用），`UserByToken` 只按 token 查：

```go
// internal/store/users.go:126
func (s *Store) UserByToken(token string) (*User, error) {
    if token == "" {
        return nil, ErrNotFound
    }
    return s.scanUser(s.db.QueryRow(
        `SELECT u.id, u.name, u.password_hash, u.is_admin, u.primary_image_tag, u.created_at
         FROM users u JOIN tokens t ON t.user_id = u.id WHERE t.token = ?`, token,
    ))
}
```

`DeleteToken` 写好了但没有任何路由调用它。

后果：

- 每次登录插一行 token，永不清；
- token 泄露后无法失效；
- `token_ttl` 是个"假配置"。

建议：查询加 `AND t.created_at >= ?`（TTL 生效）+ 补 `POST /emby/Sessions/Logout`
+ 同用户重新登录时清理旧 token。

### 5. `play_sessions` 只写不读，也没有过期

`SavePlaySession` 在每次进度上报（10 秒一次）时 UPSERT，只有条目被删除时才清理。
片子一直在 → 行数只增不减。

要么接"正在播放"看板把它读起来，要么加 `updated_at < now-1h` 的定期清理。

### 6. 后台 goroutine 没有 recover

`handleLibraryRefresh`、`scanLibraryAsync`、`rebuildLibraryCovers` 都是裸 `go func()`。
`withRecover` 只覆盖 HTTP goroutine，**后台任务里任何 nil 解引用都会直接打死进程**——
而扫描/ffmpeg 恰恰是最容易出错的路径。

建议抽一个 `goSafe(fn)` 统一包 recover + 日志。

### 7. 默认管理员密码明文进日志

```go
// cmd/embyx/main.go:86
log.Printf("Emby 兼容服务已启动: http://localhost%s/emby", cfg.Addr)
log.Printf("默认账号: %s / %s", cfg.AdminUser, cfg.AdminPassword)
```

日志会轮转到 `embyx.log` 并长期保留（还可能被用户贴到 issue 里）。
建议只在"密码仍是内置默认值 `admin`"时提示"请尽快修改密码"，不打印实际值。

### 8. BIF 播放侧固定 10 秒，预生成允许 2~600 秒

`handleBif` 硬编码 `intervalMs = 10000`，而 `POST /emby/ThumbnailJobs` 允许用户设 2~600 秒。
当用户预生成 5 秒间隔时，播放请求找不到精确匹配，走 `anyVariant` 复用了 5 秒文件。

如果客户端按"帧序号 × 头部 interval"解析就没问题；若前端假设固定 10 秒就会错位。
建议确认客户端读头部 interval，或在 `handleBif` 加一个 `IntervalMs` 参数。

---

## 二、性能（按收益排序）

### 1. 列表接口把详情数据一起返回了（收益最大）

`ToDto` 无条件构造 `MediaSources`（内含全部 `MediaStreams`），并且 `People`/`Chapters` 也照搬：

```go
// internal/store/items.go:686
if item.Path != "" {
    result.MediaSources = []dto.MediaSourceInfo{item.ToMediaSource()}
}
```

`/Users/{id}/Items?Limit=100` 一次返回 100 条 ×（5~8 条流 + 20~30 个演员 + 章节），
一部片几百字节到几 KB，一屏就是几百 KB JSON，且 Flutter 侧要全量解析。

建议给 `ItemQuery` 加 `Detail bool`（或 `Fields []string`），列表模式只输出
ID / Name / ImageTags / UserData / RunTimeTicks 这类卡片必需字段。
这是这类项目的标准做法。

### 2. 播放/图片路径用 `GetItem` 拉全行

`handleStream`、`handleBif` 只为拿 `Path`，却扫描 32 列 + 反序列化 11 个 JSON 字段。
播放时 mpv 拖动进度条 = 密集 Range 请求，每次都要付这个成本。

`store.ItemSource` 已经存在且只取 5 列，直接换过去即可（`playback.go:59`、`playback.go:93`）。

### 3. `QueryItems` 无条件 `COUNT(*)`

```go
// internal/store/items.go:181
var total int
countSQL := "SELECT COUNT(*)" + fromSQL + " WHERE " + whereSQL
if err := s.db.QueryRowContext(ctx, countSQL, args...).Scan(&total); err != nil {
```

两处浪费：

1. 翻页时 `StartIndex > 0` 仍在重复统计全量；
2. `handleLatestItems` 明确丢弃了 total（`items.go:106`）却还是白跑一次 COUNT。

建议 `ItemQuery` 加 `SkipTotal bool`。

### 4. 每个请求一次 token 查库

`withAuth` → `UserByToken` → `tokens JOIN users`。图片列表一屏几十个请求 = 几十次 SQL；
视频流每个 Range 请求一次。

加一个 `map[token]cachedUser`（TTL 1~5 分钟，登录/登出时失效）能直接砍掉这条路径上绝大部分 DB 压力。

### 5. 扫描：每文件一次 SQL + 每文件 `ReadDir` 同一目录

- `buildItem` 对每个文件调一次 `ItemFingerprint`（`scan.go:374`），1 万条目 = 1 万次单行查询；
  而 `purgeMissingItems` 之后又查一次 `LibraryItemRefs`（`scan.go:230`）。
  建议在扫描开始时**一次性**把 `id / fingerprint / nfo_mtime / path` 读进 map，
  一次遍历同时完成"指纹比对 + 陈旧条目判定"。
- `FindArtwork` + `FindActorImages` 对同目录下每个视频各 `ReadDir` 两次
  （`artwork.go:32`、`artwork.go:103`）。一个目录 100 部片 = 200 次目录枚举。
  **网络盘上这是扫描里最贵的一环。** 建议在 `processFiles` 外层按目录缓存文件名快照，
  扫描一轮内复用。

### 6. `purgeMissingItems` / `DeleteItems` 全串行

- 前者对库里每个条目逐个 `os.Stat`（网络盘上几千次串行 RTT）；
- 后者在**单个事务里**逐条执行 3 条 DELETE（`libraries.go:242-252`），
  条目多时长时间持有写锁，会顶掉 4 个扫描 worker 的 `UpsertItem`。

前者按 worker 数并发、后者改 `IN (...)` 批量即可。

### 7. `statusRecorder` 丢掉了 `sendfile` 优化

```go
// internal/httpapi/middleware.go:50
type statusRecorder struct {
    http.ResponseWriter
    status int
    bytes  int64
    user   string
}
```

包装 `ResponseWriter` 后 `io.ReaderFrom` 不可见，`http.ServeContent` 的 `io.Copy`
由零拷贝退化为 32KB 缓冲区循环。对一个专做 4K 直连的媒体服务器，这部分 CPU 与内存带宽开销是实打实的。

补一个透传：

```go
func (r *statusRecorder) ReadFrom(src io.Reader) (int64, error) {
    if rf, ok := r.ResponseWriter.(io.ReaderFrom); ok {
        if r.status == 0 {
            r.status = http.StatusOK
        }
        n, err := rf.ReadFrom(src)
        r.bytes += n
        return n, err
    }
    return io.Copy(r.ResponseWriter, src) // 注意不要递归调用自己
}
```

### 8. 用户头像完全绕过 `ImageRenderer`

`handleUserAvatar` 直接 `media.Render(...)`（`auth.go:74`），没有磁盘缓存、
没有 singleflight、没有并发信号量。人物详情页 + 演职员列表会反复请求同一张头像。

把它接到 `imageRenderer.Render(userID, "Primary", 0, raw, maxWidth, quality)` 上，
零成本获得缓存与 ETag。

### 9. 三处明显的热点代码

| 位置 | 问题 | 建议 |
|---|---|---|
| `library_cover.go:231` | `applyVignette` 对 1280×720 逐像素 `math.Hypot`（92 万次 sqrt） | factor 只需 `1-0.35*(dx²+dy²)/(cx²+cy²)`，完全不需 sqrt |
| `bif.go:132` | `anyVariant` 每次播放请求 `ReadDir` 整个 BIF 目录 | 内存索引（itemID → 文件名/mtime），或只 stat 两种命名 |
| `browse.go:19` | `Genres/Tags/Studios` 每次筛选栏展开都全表 `json_each` + GROUP BY | 加一层短 TTL 内存缓存（数据只在扫描后变化） |

### 10. 索引缺口

- `items` 缺 `(library_id, date_created)` 复合索引 → `RecentLibraryItemIDs` 每次都要临时 B 树排序；
- `user_data` 缺 `(user_id, played, last_played_date)` → "继续观看"的
  `playback_position_ticks > 0 AND played = 0` 用不上现有索引。

---

## 三、代码质量

1. **两套 job manager 是复制粘贴**
   `ArtworkJobManager` 与 `ThumbnailJobManager` 的
   `Start / Snapshot / Cancel / trimLocked / order / jobs / active / parentCtx`
   结构几乎逐行相同（`artwork_job.go:97-280` vs `thumbnail_job.go:119-451`），
   只有 `run` 的循环体不同。用泛型抽象掉外壳，能删掉 150+ 行重复代码和两套 `ErrXxxJobRunning`。

2. **`itemLocks` 三份**
   `Scanner.artLocks`、`ArtworkGenerator.itemLocks`、`BifCache.itemLocks` 是同一个
   "按 key 加锁 + 锁表只增不减"的模式。抽一个 `keyedMutex` 约 20 行，
   还能顺手解决**锁表永不释放**（长期运行条目越删越多，map 只涨不落，虽然量级不大）。

3. **`Prober` 建了两次**
   `main.go:57` 一个给 scanner，`httpapi.New` 里又 `media.NewProber(cfg.FFprobePath)`
   一个给 artwork。把已有的传进去即可。

4. **`normalizeImageType` 两份**
   `httpapi/images.go:336` 与 `media/artwork_gen.go:328`，且语义不同
   （一个输出 `"Primary"`，一个输出 `ArtworkPrimary` 常量），后续容易改漏。

5. **`sanitizeID` 没用在 `imageType` 上**
   `ImageStore.ItemPath` 对 itemID 做了清洗，但对 `imageType` 只有 `strings.ToLower`
   （`image.go:37`）。目前 `http.ServeMux` 会清理 path 中的 `..`，实际难以穿越，
   但上传接口把请求体直接写到这个路径，属于"防御缺失"。建议对 `imageType` 也过一次白名单。

6. **`getRawItem` 用 `ud.user_id = ''` 凑列数**（`items.go:317`）
   能跑，但读代码时很迷惑。可以抽一个不含 `userDataColumns` 的查询分支。

7. **schema 只能"删库重建"**
   `prepareSchema` 版本不一致直接拒绝启动（`store.go:79`）。个人项目可以接受，
   但每加一个字段就要用户重扫全库。建议引入最简单的 `migrations []string`
   （按 `user_version` 递增执行 `ALTER TABLE ADD COLUMN`），后续加列都能平滑升级。

8. **测试分布不均**
   `media` / `store` 覆盖不错，`httpapi` 只有 `auth_test` / `s3_test`，
   而路由、鉴权、`QueryItems` 参数解析、图片 ETag 这些地方恰恰最容易回归。
   至少给 `handleItems` 的参数 → `ItemQuery` 映射、`withAuth` 的四种 token 来源补上表驱动测试。

---

## 四、建议的动手顺序

| 优先级 | 事项 | 理由 |
|---|---|---|
| P0 | BIF 超时按 `force` 判断（一.1）、后台 goroutine 加 recover（一.6） | 一个让功能实际不可用，一个让单点错误升级为进程崩溃 |
| P0 | 列表接口瘦身（二.1） | 收益最大、改动局部，`BaseItemDto` 已有 omitempty |
| P1 | 播放/图片改用轻量查询（二.2）、`ReadFrom` 透传（二.7） | 播放路径上的直接开销 |
| P1 | token TTL + 登出 + 清理（一.4）、密码不进日志（一.7） | 安全性，且 `TokenTTL` 现在是个"假配置" |
| P2 | 扫描一次性读索引 + 目录快照缓存（二.5） | 大库/网络盘扫描时间可能砍半 |
| P2 | 删库清 BIF（一.2）、`bif-*` 残留清理（一.3） | 磁盘泄漏，纯 bug |
| P3 | job manager 泛型化、`keyedMutex` 抽取（三.1、三.2） | 纯代码整洁，可在改上面几条时顺带做 |
