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
	"syscall"
	"time"

	"embyx/internal/config"
	"embyx/internal/httpapi"
	"embyx/internal/media"
	"embyx/internal/store"
)

func main() {
	setupLogging()

	configPath := flag.String("config", "", "配置文件路径（默认 ./config.yaml，也可用 EMBYX_CONFIG 指定）")
	flag.Parse()

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
	scanner := media.NewScanner(st, prober, images)

	api := httpapi.New(cfg, st, images, bifCache, scanner)

	server := &http.Server{
		Addr:              cfg.Addr,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// 视频流是长连接，不能设置整体写超时。
		IdleTimeout: 120 * time.Second,
	}

	go func() {
		log.Printf("Emby 兼容服务已启动: http://localhost%s/emby", cfg.Addr)
		log.Printf("默认账号: %s / %s", cfg.AdminUser, cfg.AdminPassword)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("服务启动失败: %v", err)
		}
	}()

	// 媒体库完全由设置页（VirtualFolders 接口）维护，
	// 启动时既不初始化也不扫描，这里只打印数据库里已有的数量。
	if libraries, err := st.Libraries(context.Background()); err == nil {
		log.Printf("已配置媒体库 %d 个（扫描需手动触发）", len(libraries))
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	log.Println("正在关闭服务...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("关闭服务异常: %v", err)
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

	// 超过 5MB 滚动一次，避免长期运行把磁盘写满。
	if info, statErr := os.Stat(logPath); statErr == nil && info.Size() > 5<<20 {
		_ = os.Rename(logPath, logPath+".old")
	}

	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	log.SetOutput(io.MultiWriter(os.Stderr, file))
}
