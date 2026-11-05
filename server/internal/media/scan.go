package media

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"

	"embyx/internal/dto"
	"embyx/internal/store"
)

var videoExtensions = map[string]bool{
	".mkv": true, ".mp4": true, ".avi": true, ".mov": true,
	".wmv": true, ".ts": true, ".m2ts": true, ".flv": true, ".webm": true, ".rmvb": true,
}

var skipDirs = map[string]bool{
	"@eadir": true, "#recycle": true, "$recycle.bin": true,
	"system volume information": true, ".git": true,
}

// 匹配 "标题 (2023)" / "标题.2023.1080p" 中的年份。
var yearPattern = regexp.MustCompile(`(?:^|[.\-_\[\]( ])((?:19|20)\d{2})(?:[.\-_\[\]) ]|$)`)

type Scanner struct {
	store  *store.Store
	prober *Prober
	images *ImageStore
	// bif 用于在条目删除时回收进度条缩略图缓存，可为 nil。
	bif *BifCache

	// workers 是并发探测/入库的 worker 数量，同时也是 ffprobe 的并发上限。
	workers int
	// scanMu 保证同一时刻只有一个扫描在跑，避免重复点击并发遍历同一目录。
	scanMu sync.Mutex
	// progress 是供 /Library/ScanStatus 读取的实时进度，不参与扫描逻辑。
	progress scanProgress
	// artLocks 按图片目标路径加锁：演员头像被多个条目共用，并发写同一文件会重复转码。
	artLocks keyedMutex
	// scanStates 是本次扫描开始时一次性读入的条目指纹。
	// worker 只读这张表，不必为每个文件查一次库。
	scanStates map[string]store.ItemScanState
	// lockedEntities 是本次扫描开始时一次性读入的图片锁（条目 / 人物 / 媒体库）。
	// 锁只挡自动流程，手动上传、生成、删除不受影响。
	lockedEntities map[string]bool
	// dirCache 缓存本次扫描内的目录枚举结果：一个目录 100 部片原本要 ReadDir 200 次。
	dirMu    sync.Mutex
	dirCache map[string]*dirSnapshot
	// onItemRemoved 是条目删除后的清理回调（缓存回收注入），可为 nil。
	onItemRemoved func(itemID string)
	// onScanFinished 在扫描结束后回调本次涉及的媒体库 ID（派生数据重建注入），可为 nil。
	onScanFinished func(libraryIDs []string)
}

func NewScanner(s *store.Store, prober *Prober, images *ImageStore, bif *BifCache) *Scanner {
	return &Scanner{
		store:   s,
		prober:  prober,
		images:  images,
		bif:     bif,
		workers: scanWorkers(),
	}
}

// SetItemRemovedHook 注册条目删除后的清理回调（S4.1 用它立即回收缩放缓存）。
// 不放进构造函数：缓存回收是可选的运维组件，扫描本身不依赖它。
func (s *Scanner) SetItemRemovedHook(hook func(itemID string)) {
	s.onItemRemoved = hook
}

// SetScanFinishedHook 注册扫描结束回调（媒体库封面等派生数据重建用）。
// 扫描是条目增删的唯一入口，创建库、手动扫描、片源变动最终都会走到这里。
func (s *Scanner) SetScanFinishedHook(hook func(libraryIDs []string)) {
	s.onScanFinished = hook
}

// notifyScanFinished 把本次扫描涉及的库交给回调。回调负责异步处理，
// 这里只做一次投递，不阻塞扫描令牌的释放。
func (s *Scanner) notifyScanFinished(libraryIDs []string) {
	if s.onScanFinished == nil || len(libraryIDs) == 0 {
		return
	}
	s.onScanFinished(libraryIDs)
}

// scanWorkers 决定扫描并发度。耗时几乎全在 ffprobe 子进程和图片转码上，
// 但两者都要抢同一块磁盘，worker 过多反而因随机读变慢，所以上限压到 4。
func scanWorkers() int {
	count := runtime.GOMAXPROCS(0)
	if count > 4 {
		count = 4
	}
	if count < 1 {
		count = 1
	}
	return count
}

// ScanAll 扫描数据库中配置的全部媒体库。
func (s *Scanner) ScanAll(ctx context.Context, logf func(string, ...any)) (int, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	if !s.beginScan(logf) {
		return 0, nil
	}
	// defer 是后进先出：progress.finish → Unlock → 回调，
	// 保证回调执行时扫描状态已标记完成、扫描令牌也已释放。
	scannedLibraries := make([]string, 0, 8)
	defer func() { s.notifyScanFinished(scannedLibraries) }()
	defer s.scanMu.Unlock()
	defer s.progress.finish()

	libraries, err := s.store.Libraries(ctx)
	if err != nil {
		return 0, err
	}
	if len(libraries) == 0 {
		logf("尚未配置媒体库，跳过扫描")
		return 0, nil
	}

	total := 0
	for _, lib := range libraries {
		imported, scanErr := s.scanLibrary(ctx, lib, logf)
		total += imported
		// 扫描失败也记入：条目可能已有增删，覆盖按当前条目重建仍然是对的。
		scannedLibraries = append(scannedLibraries, lib.ID)
		if scanErr != nil {
			logf("扫描媒体库 %s 失败: %v", lib.Name, scanErr)
		}
	}
	logf("全部扫描完成，共导入 %d 个条目", total)
	return total, nil
}

// ScanLibrary 扫描单个媒体库的所有目录；重复执行是幂等的（条目 ID 由路径派生）。
func (s *Scanner) ScanLibrary(ctx context.Context, lib store.Library, logf func(string, ...any)) (int, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	if !s.beginScan(logf) {
		return 0, nil
	}
	// 与 ScanAll 相同：先置完成状态并释放令牌，最后通知派生数据重建。
	defer func() { s.notifyScanFinished([]string{lib.ID}) }()
	defer s.scanMu.Unlock()
	defer s.progress.finish()
	return s.scanLibrary(ctx, lib, logf)
}

// beginScan 抢扫描令牌；已有扫描在跑时返回 false。
func (s *Scanner) beginScan(logf func(string, ...any)) bool {
	if s.scanMu.TryLock() {
		s.progress.begin()
		return true
	}
	logf("已有扫描正在进行中，跳过本次扫描")
	return false
}

// scanLibrary 是扫描的实际实现，调用方必须已持有 scanMu。
// 目录遍历保持串行（本身很快），ffprobe 与图片转码交给 worker 并发处理。
func (s *Scanner) scanLibrary(ctx context.Context, lib store.Library, logf func(string, ...any)) (int, error) {
	if len(lib.Paths) == 0 {
		logf("媒体库 %s 没有配置目录，跳过", lib.Name)
		return 0, nil
	}

	// 本次扫描专用的一次性快照：条目指纹与目录枚举结果都只读一次，worker 共享。
	s.prepareScanCache(ctx, logf)
	defer s.clearScanCache()

	imported := 0
	for _, root := range lib.Paths {
		if info, err := os.Stat(root); err != nil || !info.IsDir() {
			logf("媒体库 %s 的目录不可访问，跳过: %s", lib.Name, root)
			continue
		}
		logf("扫描媒体库 %s (%s)", lib.Name, root)
		s.progress.setLibrary(lib.ID, lib.Name)

		paths, err := collectVideoFiles(ctx, root)
		// 先登记本目录的待处理数，进度条才能从一开始就有分母。
		s.progress.addFiles(len(paths))
		if err != nil && !errors.Is(err, context.Canceled) {
			return imported, err
		}
		imported += s.processFiles(ctx, lib.ID, root, paths, logf)
		// 遍历成功才清理陈旧条目：源端删片后重新扫描即可同步，避免条目长期残留。
		if err == nil {
			s.purgeMissingItems(ctx, lib, root, paths, logf)
		}
		if ctx.Err() != nil {
			break
		}
	}
	logf("媒体库 %s 扫描完成，共处理 %d 个条目", lib.Name, imported)
	return imported, nil
}

// dirSnapshot 是同一目录下图片与演员头像的一次性枚举结果。
type dirSnapshot struct {
	// images 是小写文件名（不含扩展名）→ 完整路径，只含图片扩展名。
	images map[string]string
	// actors 来自 .actors 子目录，演员名 → 头像路径。
	actors map[string]string
}

// prepareScanCache 在扫描开始时准备两类快照，读完即固定，扫描期间不再变化。
func (s *Scanner) prepareScanCache(ctx context.Context, logf func(string, ...any)) {
	s.dirMu.Lock()
	s.dirCache = make(map[string]*dirSnapshot)
	s.dirMu.Unlock()

	states, err := s.store.ScanStates(ctx)
	if err != nil {
		// 读不到就退回逐条查询，功能不变，只是慢一点。
		logf("读取条目扫描状态失败，本次扫描逐条查询: %v", err)
		return
	}
	s.scanStates = states

	if locked, lockErr := s.store.ImageLockedEntities(ctx); lockErr == nil {
		s.lockedEntities = locked
	} else {
		// 读不到锁时按未锁定处理：宁可让目录图更新，也不能把误锁当成保护。
		logf("读取图片锁失败，本次扫描按未锁定处理: %v", lockErr)
	}
}

// entityLocked 查询本次扫描的图片锁集合，未加载时按未锁定处理。
func (s *Scanner) entityLocked(entityID string) bool {
	if s.lockedEntities == nil {
		return false
	}
	return s.lockedEntities[entityID]
}

// clearScanCache 丢弃本次扫描的快照，避免长期持有大库的内存副本。
// 必须在所有 worker 结束后调用。
func (s *Scanner) clearScanCache() {
	s.dirMu.Lock()
	s.dirCache = nil
	s.dirMu.Unlock()
	s.scanStates = nil
	s.lockedEntities = nil
}

// snapshotDir 返回目录快照，同一次扫描内复用。
func (s *Scanner) snapshotDir(dir string) *dirSnapshot {
	s.dirMu.Lock()
	snapshot, ok := s.dirCache[dir]
	s.dirMu.Unlock()
	if ok {
		return snapshot
	}

	snapshot = &dirSnapshot{images: readImageIndex(dir), actors: readActorIndex(dir)}

	s.dirMu.Lock()
	if s.dirCache == nil {
		s.dirCache = make(map[string]*dirSnapshot)
	}
	s.dirCache[dir] = snapshot
	s.dirMu.Unlock()
	return snapshot
}

// storedState 优先用扫描开始时的内存快照，缺失时退回一次单行查询。
func (s *Scanner) storedState(ctx context.Context, itemID string) (store.ItemScanState, bool) {
	if s.scanStates != nil {
		state, ok := s.scanStates[itemID]
		return state, ok
	}
	fingerprint, nfoMtime, err := s.store.ItemFingerprint(ctx, itemID)
	if err != nil {
		return store.ItemScanState{}, false
	}
	return store.ItemScanState{Fingerprint: fingerprint, NFOMtime: nfoMtime}, true
}

// collectVideoFiles 串行遍历目录，只收集候选视频文件的路径。
func collectVideoFiles(ctx context.Context, root string) ([]string, error) {
	paths := make([]string, 0, 256)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if entry.IsDir() {
			if skipDirs[strings.ToLower(entry.Name())] {
				return fs.SkipDir
			}
			return nil
		}
		if !videoExtensions[strings.ToLower(filepath.Ext(path))] {
			return nil
		}
		paths = append(paths, path)
		return nil
	})
	return paths, err
}

// purgeMissingItems 删除源文件已经不存在的条目，同时回收图片与用户数据。
// 安全前提：只在本次遍历成功且确实扫到文件时执行，共享盘掉线时不会被当成"全库删除"。
func (s *Scanner) purgeMissingItems(ctx context.Context, lib store.Library, root string, scanned []string, logf func(string, ...any)) {
	if len(scanned) == 0 || ctx.Err() != nil {
		return
	}
	refs, err := s.store.LibraryItemRefs(ctx, lib.ID)
	if err != nil {
		logf("媒体库 %s 清理陈旧条目失败: %v", lib.Name, err)
		return
	}

	seen := make(map[string]bool, len(scanned))
	for _, path := range scanned {
		seen[path] = true
	}

	// 逐个 os.Stat 在网络盘上是几千次串行 RTT，这里按扫描 worker 数并发探测。
	candidates := make([]store.LibraryItemRef, 0, len(refs))
	for _, ref := range refs {
		if seen[ref.Path] || !pathWithinRoot(ref.Path, root) {
			continue
		}
		candidates = append(candidates, ref)
	}

	stale := make([]string, 0, len(candidates))
	var (
		staleMu sync.Mutex
		wg      sync.WaitGroup
	)
	workers := s.workers
	if workers < 1 {
		workers = scanWorkers()
	}
	sem := make(chan struct{}, workers)
	for _, ref := range candidates {
		if ctx.Err() != nil {
			break
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(ref store.LibraryItemRef) {
			defer wg.Done()
			defer func() { <-sem }()
			// 只有"确实不存在"才删：权限不足、网络不可达等情况保守保留。
			if _, statErr := os.Stat(ref.Path); !errors.Is(statErr, fs.ErrNotExist) {
				return
			}
			staleMu.Lock()
			stale = append(stale, ref.ID)
			staleMu.Unlock()
		}(ref)
	}
	wg.Wait()
	if len(stale) == 0 {
		return
	}

	if err := s.store.DeleteItems(ctx, stale); err != nil {
		logf("媒体库 %s 删除陈旧条目失败: %v", lib.Name, err)
		return
	}
	for _, itemID := range stale {
		_ = s.images.RemoveItem(itemID)
		s.removeCachedBif(itemID)
		if s.onItemRemoved != nil {
			s.onItemRemoved(itemID)
		}
	}
	logf("媒体库 %s 清理了 %d 个源文件已不存在的条目", lib.Name, len(stale))
}

// pathWithinRoot 判断条目路径是否位于扫描根目录下，多目录库之间不会互相清理。
func pathWithinRoot(path, root string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// processFiles 用固定数量的 worker 并发探测并入库，返回成功导入的条目数。
// 每个文件只会进入一个 worker，buildItem 对 item 的原地修改不存在竞争。
func (s *Scanner) processFiles(ctx context.Context, libraryID, root string, paths []string, logf func(string, ...any)) int {
	if len(paths) == 0 {
		return 0
	}
	workerCount := s.workers
	if workerCount < 1 {
		workerCount = scanWorkers()
	}
	if workerCount > len(paths) {
		workerCount = len(paths)
	}

	var imported atomic.Int64
	jobs := make(chan string)
	var wg sync.WaitGroup
	wg.Add(workerCount)
	for i := 0; i < workerCount; i++ {
		go func() {
			defer wg.Done()
			for path := range jobs {
				// 取消后继续排空 channel，避免发送方阻塞。
				if ctx.Err() != nil {
					continue
				}
				item, needWrite, buildErr := s.buildItem(ctx, libraryID, root, path, logf)
				if buildErr != nil {
					if ctx.Err() == nil {
						logf("跳过 %s: %v", path, buildErr)
						s.progress.addFailure(path, buildErr)
					}
					continue
				}
				if !needWrite {
					// 指纹命中：片源与 NFO 都没变，路径已在 buildItem 里纠正，无需再写库。
					imported.Add(1)
					s.progress.markScanned(path)
					continue
				}
				if err := s.store.UpsertItem(ctx, item); err != nil {
					if ctx.Err() == nil {
						logf("入库失败 %s: %v", path, err)
						s.progress.addFailure(path, err)
					}
					continue
				}
				imported.Add(1)
				s.progress.markScanned(path)
			}
		}()
	}

	for _, path := range paths {
		if ctx.Err() != nil {
			break
		}
		jobs <- path
	}
	close(jobs)
	wg.Wait()
	return int(imported.Load())
}

// buildItem 探测单个文件并构造条目。
// needWrite 为 false 表示片源与 NFO 都没有变化，条目内容无需改写，只就地纠正了路径。
func (s *Scanner) buildItem(ctx context.Context, libraryID, root, path string, logf func(string, ...any)) (*store.Item, bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, false, err
	}
	fingerprint := fileFingerprint(info)

	// NFO 只是一个很小的文件，解析很便宜，但它决定条目 ID，
	// 所以必须在探测前完成；解析失败时退回按路径派生 ID。
	var (
		nfo      *NFOData
		nfoMtime int64
	)
	if nfoPath := FindNFO(path); nfoPath != "" {
		if nfoInfo, statErr := os.Stat(nfoPath); statErr == nil {
			nfoMtime = nfoInfo.ModTime().UnixNano()
		}
		parsed, parseErr := ParseNFO(nfoPath)
		if parseErr != nil {
			logf("NFO 解析失败 %s: %v", nfoPath, parseErr)
		} else {
			nfo = parsed
		}
	}

	itemID := deriveItemID(nfo, libraryID, root, path)

	// 指纹一致说明片源没换过、NFO 也没改过：
	// 只纠正路径与库归属，跳过 ffprobe 与图片导入——大库重复扫描的耗时几乎都在这里。
	if state, ok := s.storedState(ctx, itemID); ok &&
		state.Fingerprint == fingerprint && state.NFOMtime == nfoMtime {
		// 快照里已有路径时比对一下，没变就不写库：未变动的文件原本也要 UPDATE 一次。
		if state.LibraryID != libraryID || state.Path != path {
			if err := s.store.UpdateItemLocation(ctx, itemID, libraryID, path); err != nil {
				return nil, false, err
			}
		}
		return nil, false, nil
	}

	probe, err := s.prober.Probe(ctx, path)
	if err != nil {
		return nil, false, err
	}

	fileTitle, fileYear := parseFileName(filepath.Base(path))
	item := &store.Item{
		ID: itemID,
		// Emby 语义里媒体库是条目的父节点，客户端浏览库内内容时传 ParentId=<库ID>。
		LibraryID:      libraryID,
		ParentID:       libraryID,
		Type:           "Movie",
		Name:           fileTitle,
		SortName:       fileTitle,
		Path:           path,
		Container:      probe.Container,
		Size:           probe.Size,
		Bitrate:        probe.Bitrate,
		RunTimeTicks:   probe.DurationTicks,
		Width:          probe.Width,
		Height:         probe.Height,
		MediaStreams:   probe.Streams,
		Genres:         []string{},
		Tags:           []string{},
		Studios:        []dto.NameIDPair{},
		People:         []dto.PersonDto{},
		Chapters:       []dto.ChapterInfo{},
		ProviderIDs:    map[string]string{},
		ExternalURLs:   []dto.ExternalURL{},
		ImageTags:      map[string]string{},
		BackdropTags:   []string{},
		ScreenshotTags: []string{},
		Fingerprint:    fingerprint,
		NFOMtime:       nfoMtime,
	}
	if fileYear != 0 {
		year := fileYear
		item.ProductionYear = &year
	}

	// NFO 优先于文件名推断；解析失败时保留文件名结果。
	if nfo != nil {
		applyNFO(item, nfo)
	}
	if item.Name == "" {
		item.Name = fileTitle
		item.SortName = fileTitle
	}
	if item.SortName == "" {
		item.SortName = item.Name
	}
	if item.DateCreated == "" {
		item.DateCreated = store.NowISO()
	}

	// 本地图片按 Kodi 命名规则导入，演员头像取 .actors 目录。
	s.importArtwork(item, path, logf)
	logf("入库 %s", item.Name)
	return item, true, nil
}

// deriveItemID 让条目 ID 尽量与文件名解耦：
// 有 TMDB/IMDb 编号时用编号派生，改名、换目录都不会丢播放进度与收藏；
// 没有 NFO 时才退回「媒体库 ID + 相对库根的路径」，这样整个库换盘符也保持不变。
func deriveItemID(nfo *NFOData, libraryID, root, path string) string {
	if nfo != nil {
		if tmdb := strings.TrimSpace(nfo.UniqueIDs["tmdb"]); tmdb != "" {
			return store.StableID("tmdb:" + tmdb)
		}
		if imdb := strings.TrimSpace(nfo.UniqueIDs["imdb"]); imdb != "" {
			return store.StableID("imdb:" + imdb)
		}
	}
	relative := path
	if root != "" {
		if rel, err := filepath.Rel(root, path); err == nil {
			relative = rel
		}
	}
	// 统一分隔符并转小写：Windows 路径大小写不敏感，同一文件不应派生出两个 ID。
	return store.StableID("item:" + libraryID + ":" + strings.ToLower(filepath.ToSlash(relative)))
}

// fileFingerprint 用体积与修改时间组合指纹：两者都没变就认为文件内容没变。
func fileFingerprint(info os.FileInfo) string {
	return fmt.Sprintf("%d:%d", info.Size(), info.ModTime().UnixNano())
}

// removeCachedBif 回收条目的进度条缩略图缓存，缓存未启用时直接跳过。
func (s *Scanner) removeCachedBif(itemID string) {
	if s.bif == nil {
		return
	}
	s.bif.RemoveItem(itemID)
}

// parseFileName 从文件名推断标题与年份，覆盖常见的 "标题 (2023)" 与 "标题.2023.1080p" 写法。
func parseFileName(fileName string) (string, int) {
	base := strings.TrimSuffix(fileName, filepath.Ext(fileName))
	base = strings.TrimSpace(base)

	year := 0
	title := base
	if match := yearPattern.FindStringSubmatchIndex(base); match != nil {
		year = parseInt(base[match[2]:match[3]])
		title = strings.TrimSpace(base[:match[0]])
		if title == "" {
			title = strings.TrimSpace(base[match[1]:])
		}
	}
	title = cleanTitle(title)
	if title == "" {
		title = base
	}
	return title, year
}

var titleSeparators = regexp.MustCompile(`[._]+`)

func cleanTitle(value string) string {
	cleaned := titleSeparators.ReplaceAllString(value, " ")
	cleaned = strings.ReplaceAll(cleaned, "  ", " ")
	return strings.Trim(cleaned, " .-_[](){}")
}

func (s *Scanner) String() string {
	return fmt.Sprintf("Scanner{prober=%s}", s.prober.ffprobePath)
}
