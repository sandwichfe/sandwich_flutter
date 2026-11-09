package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"embyx/internal/config"
	"embyx/internal/httpapi"
	"embyx/internal/media"
	"embyx/internal/metadata"
	"embyx/internal/store"
)

func main() {
	setupLogging()

	// rootCtx 是后台任务（媒体扫描、海报生成、BIF 预生成）的父 context。
	// 收到 Ctrl+C 后先取消它让 ffmpeg 子进程结束，再关闭 HTTP 服务。
	rootCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	configPath := flag.String("config", "", "配置文件路径（默认 ./config.yaml，也可用 EMBYX_CONFIG 指定）")
	flag.Parse()

	if wd, err := os.Getwd(); err == nil {
		log.Printf("工作目录: %s", wd)
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("加载配置失败: %v", err)
	}
	log.Printf("配置文件: %s", cfg.ConfigPath)

	dbPath := filepath.Join(cfg.DataDir, "embyx.db")
	st, err := store.Open(dbPath)
	if err != nil {
		log.Fatalf("初始化数据库失败: %v", err)
	}
	defer st.Close()

	if err := st.EnsureAdmin(cfg.AdminUser, cfg.AdminPassword); err != nil {
		log.Fatalf("初始化管理员失败: %v", err)
	}
	log.Printf("数据库: %s", dbPath)

	images := media.NewImageStore(filepath.Join(cfg.DataDir, "images"))
	bifCache := media.NewBifCache(filepath.Join(cfg.DataDir, "cache", "bif"), cfg.FFmpegPath)
	prober := media.NewProber(cfg.FFprobePath)
	scanner := media.NewScanner(st, prober, images, bifCache)
	thumbs := media.NewThumbnailJobManager(bifCache)

	// 演员刮削只在手动触发时联网。来源优先级：
	// MinnanoAV > JavDatabase > JavModel > JavDB（仅链接）> TMDB（兜底）。
	var tmdbClient *metadata.Client
	if strings.TrimSpace(cfg.TmdbAPIKey) != "" {
		client, err := metadata.NewClient(cfg.TmdbAPIKey, cfg.TmdbLanguage, cfg.TmdbProxy)
		if err != nil {
			log.Fatalf("初始化 TMDB 客户端失败: %v", err)
		}
		client.SetRateLimit(cfg.TmdbRateLimit)
		tmdbClient = client
	}

	sources := make([]metadata.PersonSource, 0, 4)
	if cfg.JavEnabled {
		minnano, err := metadata.NewMinnanoAVSource("", cfg.JavProxy, cfg.JavUserAgent, cfg.JavRateLimit)
		if err != nil {
			log.Fatalf("初始化 MinnanoAV 数据源失败: %v", err)
		}
		javDatabase, err := metadata.NewJavDatabaseSource("", cfg.JavProxy, cfg.JavUserAgent, cfg.JavRateLimit)
		if err != nil {
			log.Fatalf("初始化 JavDatabase 数据源失败: %v", err)
		}
		javModel, err := metadata.NewJavModelSource("", cfg.JavProxy, cfg.JavUserAgent, cfg.JavRateLimit)
		if err != nil {
			log.Fatalf("初始化 JavModel 数据源失败: %v", err)
		}
		javDB, err := metadata.NewJavDBSource("", cfg.JavProxy, cfg.JavUserAgent, cfg.JavRateLimit)
		if err != nil {
			log.Fatalf("初始化 JavDB 数据源失败: %v", err)
		}
		sources = append(sources, minnano, javDatabase, javModel, javDB)
	}

	var personScrape *metadata.PersonScrapeJobManager
	if tmdbClient != nil || len(sources) > 0 {
		scraper := metadata.NewPersonScraper(st, images, tmdbClient, cfg.TmdbMaxBackdrops)
		scraper.SetLogger(func(format string, args ...any) { log.Printf(format, args...) })
		scraper.SetSourceProxy(cfg.JavProxy)
		for _, source := range sources {
			scraper.AddSource(source)
		}
		personScrape = metadata.NewPersonScrapeJobManager(scraper)
		log.Printf("演员刮削已启用: AV来源=%d个 限速=%d 次/秒 写真上限=%d TMDB=%v 代理=%v",
			len(sources), cfg.JavRateLimit, cfg.TmdbMaxBackdrops, tmdbClient != nil, cfg.JavProxy != "")
	}

	api := httpapi.New(cfg, st, images, bifCache, scanner, thumbs, prober, personScrape)
	api.SetBaseContext(rootCtx)

	// 缓存回收（S4.1）：启动先跑一轮，之后按 cache.sweep_interval 巡检。
	// 条目删除时通过扫描器回调立即清，其余残留交给定时任务。
	janitor := media.NewCacheJanitor(
		filepath.Join(cfg.DataDir, "cache", "images"),
		filepath.Join(cfg.DataDir, "cache", "bif"),
		int64(cfg.CacheImageLimitMB)<<20,
		int64(cfg.CacheBifLimitMB)<<20,
		st.CacheOwners,
		api.ImageRenderer(),
	)
	scanner.SetItemRemovedHook(janitor.RemoveItem)
	go janitor.Run(rootCtx, cfg.CacheSweepInterval)

	// 播放会话只服务"正在播放"：超过 1 小时没有进度上报的记录没有价值，
	// 定期清掉，避免 play_sessions 随条目一直增长。
	media.RunSafe("清理过期播放会话", func() {
		purgeStalePlaySessions(rootCtx, st, time.Hour)
	})

	server := &http.Server{
		Addr:              cfg.Addr,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// 视频流是长连接，不能设置整体写超时。
		IdleTimeout: 120 * time.Second,
	}

	go func() {
		log.Printf("Emby 兼容服务已启动: http://localhost%s/emby", cfg.Addr)
		// 密码不进日志：日志会长期留在 embyx.log 里，也可能被贴到 issue 中。
		// 只提示账号，以及"密码还是内置默认值"这一件事。
		log.Printf("默认账号: %s", cfg.AdminUser)
		if cfg.AdminPassword == config.DefaultAdminPassword {
			log.Printf("管理员密码仍是内置默认值，请尽快修改")
		}
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("服务启动失败: %v", err)
		}
	}()

	// 媒体库完全由设置页（VirtualFolders 接口）维护，
	// 启动时既不初始化也不扫描，这里只打印数据库里已有的数量。
	if libraries, err := st.Libraries(context.Background()); err == nil {
		log.Printf("已配置媒体库 %d 个（扫描需手动触发）", len(libraries))
	}

	<-rootCtx.Done()

	log.Println("正在关闭服务...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("关闭服务异常: %v", err)
	}
}

// purgeStalePlaySessions 先清一次，之后按小时清理超过 maxAge 没有上报的播放会话。
func purgeStalePlaySessions(ctx context.Context, st *store.Store, maxAge time.Duration) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		if removed, err := st.PurgeStalePlaySessions(ctx, time.Now().Add(-maxAge)); err != nil {
			if ctx.Err() == nil {
				log.Printf("清理过期播放会话失败: %v", err)
			}
		} else if removed > 0 {
			log.Printf("已清理 %d 条过期播放会话", removed)
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// setupLogging 同时输出到控制台与 exe 同目录的 embyx.log。
// 双击运行时控制台会随进程退出关闭，日志文件是排查启动失败的唯一线索。
func setupLogging() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[embyx] ")

	executable, err := os.Executable()
	if err != nil {
		return
	}
	logPath := filepath.Join(filepath.Dir(executable), "embyx.log")

	// 按大小轮转（S4.3）：长期运行只靠启动时判断会让日志无限增长。
	writer, err := newRotatingWriter(logPath, 5<<20)
	if err != nil {
		return
	}
	log.SetOutput(io.MultiWriter(os.Stderr, writer))
}

// rotatingWriter 按大小轮转日志文件：写满 maxSize 后把当前文件改名为 .old 再重新打开。
// 轮转在写入时判断，不需要额外的定时协程；旧文件只留一份。
type rotatingWriter struct {
	mu      sync.Mutex
	path    string
	maxSize int64
	file    *os.File
	size    int64
}

func newRotatingWriter(path string, maxSize int64) (*rotatingWriter, error) {
	writer := &rotatingWriter{path: path, maxSize: maxSize}
	if err := writer.open(); err != nil {
		return nil, err
	}
	return writer, nil
}

// open 以追加方式打开日志，并记下当前长度（重启后继续按总量判断）。
func (w *rotatingWriter) open() error {
	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return err
	}
	w.file = file
	w.size = info.Size()
	return nil
}

func (w *rotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.file == nil {
		return 0, os.ErrClosed
	}
	if w.size+int64(len(p)) > w.maxSize {
		w.rotate()
	}
	n, err := w.file.Write(p)
	w.size += int64(n)
	return n, err
}

// rotate 关闭当前文件、覆盖旧备份并重新打开。任何一步失败都尽量保住可用性：
// 即使改名失败也继续往原文件写，日志丢失比进程崩溃更容易接受。
func (w *rotatingWriter) rotate() {
	_ = w.file.Close()
	_ = os.Remove(w.path + ".old")
	_ = os.Rename(w.path, w.path+".old")
	if err := w.open(); err != nil {
		w.file = nil
	}
}
