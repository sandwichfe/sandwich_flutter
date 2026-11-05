package httpapi

import (
	"context"
	"net/http"
	"path/filepath"

	"embyx/internal/config"
	"embyx/internal/media"
	"embyx/internal/store"
)

// Server 汇总所有依赖并注册 Emby 兼容路由。
type Server struct {
	cfg     config.Config
	store   *store.Store
	images  *media.ImageStore
	bif     *media.BifCache
	scanner *media.Scanner
	thumbs  *media.ThumbnailJobManager
	// artwork 按需从视频画面生成海报与封面；artworkJobs 负责整库批量生成。
	artwork     *media.ArtworkGenerator
	artworkJobs *media.ArtworkJobManager
	// imageRenderer 负责按宽度/画质缩放图片并做磁盘缓存。
	imageRenderer *media.ImageRenderer
	// libraryCovers 生成媒体库默认拼图封面（最近加入的条目海报竖切成最多 3 列拼成横屏）。
	libraryCovers *media.LibraryCoverBuilder

	// baseCtx 是后台任务（扫描、图片生成）的父 context，进程退出时取消。
	baseCtx context.Context

	mux *http.ServeMux
}

// New 装配 HTTP 层。prober 由 main 注入，和扫描器共用同一个实例，
// 避免同一个 ffprobe 可执行文件被构造两次、配置改了只生效一半。
func New(cfg config.Config, st *store.Store, images *media.ImageStore, bif *media.BifCache,
	scanner *media.Scanner, thumbs *media.ThumbnailJobManager, prober *media.Prober) *Server {
	server := &Server{
		cfg:     cfg,
		store:   st,
		images:  images,
		bif:     bif,
		scanner: scanner,
		thumbs:  thumbs,
		artwork: media.NewArtworkGenerator(images, prober, cfg.FFmpegPath),
		// 缩放结果落在数据目录下，和 BIF 缓存同级。
		imageRenderer: media.NewImageRenderer(filepath.Join(cfg.DataDir, "cache", "images")),
		libraryCovers: media.NewLibraryCoverBuilder(images, st),
		mux:           http.NewServeMux(),
	}
	// 批量任务在后台跑，生成完成后通过回调回写图片标记。
	server.artworkJobs = media.NewArtworkJobManager(server.artwork, server.markGeneratedImageTags)
	// 扫描是条目增删的唯一入口，扫描结束在这里重建媒体库拼图封面。
	if scanner != nil {
		scanner.SetScanFinishedHook(server.rebuildLibraryCovers)
	}
	server.routes()
	return server
}

// ImageRenderer 暴露缩放缓存，供 main 装配缓存回收任务（S4.1）。
// 回收按最近访问时间淘汰，必须和真正处理请求的实例是同一个。
func (s *Server) ImageRenderer() *media.ImageRenderer {
	return s.imageRenderer
}

func (s *Server) Handler() http.Handler {
	// 访问日志放在鉴权外层，才能记录到被拒绝（401/403）的请求；
	// 用户名由 withAuth 通过 statusRecorder 回填。
	return s.withRecover(s.withCORS(s.withAccessLog(s.withAuth(s.mux))))
}

// SetBaseContext 设置后台任务使用的父 context。
// 进程退出时取消它，正在跑的扫描与 ffmpeg 生成任务会一起结束。
func (s *Server) SetBaseContext(ctx context.Context) {
	s.baseCtx = ctx
	if s.artworkJobs != nil {
		s.artworkJobs.SetParentContext(ctx)
	}
	if s.thumbs != nil {
		s.thumbs.SetParentContext(ctx)
	}
	if s.bif != nil {
		s.bif.SetBaseContext(ctx)
	}
}

// baseContext 返回后台任务的父 context，未设置时退回 Background。
func (s *Server) baseContext() context.Context {
	if s.baseCtx != nil {
		return s.baseCtx
	}
	return context.Background()
}

func (s *Server) routes() {
	// 认证与系统信息
	s.mux.HandleFunc("POST /emby/Users/AuthenticateByName", s.handleAuthenticate)
	s.mux.HandleFunc("POST /emby/Sessions/Logout", s.handleLogout)
	s.mux.HandleFunc("GET /emby/System/Info/Public", s.handlePublicInfo)

	// 用户与头像
	s.mux.HandleFunc("GET /emby/Users/{userId}/Images/Primary", s.handleUserAvatar)
	s.mux.HandleFunc("POST /emby/Users/{userId}/Images/Primary", s.handleUploadUserAvatar)

	// 媒体库
	s.mux.HandleFunc("GET /emby/Users/{userId}/Views", s.handleViews)
	s.mux.HandleFunc("POST /emby/Library/Refresh", s.handleLibraryRefresh)
	// 扫描进度查询（管理员）
	s.mux.HandleFunc("GET /emby/Library/ScanStatus", s.handleScanStatus)
	s.mux.HandleFunc("GET /emby/Library/VirtualFolders", s.handleListVirtualFolders)
	s.mux.HandleFunc("POST /emby/Library/VirtualFolders", s.handleCreateVirtualFolder)
	s.mux.HandleFunc("DELETE /emby/Library/VirtualFolders", s.handleDeleteVirtualFolder)
	s.mux.HandleFunc("POST /emby/Library/VirtualFolders/Name", s.handleRenameVirtualFolder)
	s.mux.HandleFunc("PUT /emby/Library/VirtualFolders/{libraryId}", s.handleUpdateVirtualFolder)

	// 条目查询
	s.mux.HandleFunc("GET /emby/Users/{userId}/Items", s.handleItems)
	s.mux.HandleFunc("GET /emby/Users/{userId}/Items/Resume", s.handleResume)
	// Latest 是字面量路由，优先级高于下面的 {itemId}，不会互相抢。
	s.mux.HandleFunc("GET /emby/Users/{userId}/Items/Latest", s.handleLatestItems)
	s.mux.HandleFunc("GET /emby/Users/{userId}/Items/{itemId}", s.handleItemDetail)
	s.mux.HandleFunc("GET /emby/Persons", s.handlePersons)

	// 分类浏览（流派 / 工作室 / 标签），供筛选栏取候选值
	s.mux.HandleFunc("GET /emby/Genres", s.handleGenres)
	s.mux.HandleFunc("GET /emby/Studios", s.handleStudios)
	s.mux.HandleFunc("GET /emby/Tags", s.handleTags)
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Similar", s.handleSimilar)
	s.mux.HandleFunc("POST /emby/Items/{itemId}", s.handleUpdateItem)
	s.mux.HandleFunc("POST /emby/Items/{itemId}/Refresh", s.handleRefreshItem)

	// 图片
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Images", s.handleListImages)
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Images/{type}", s.handleImage)
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Images/{type}/{index}", s.handleImage)
	// 从视频画面生成海报/封面（本项目扩展，不属于 Emby 协议）。
	s.mux.HandleFunc("POST /emby/Items/{itemId}/Images/Generate", s.handleGenerateArtwork)
	s.mux.HandleFunc("POST /emby/Items/{itemId}/Images/{type}", s.handleUploadImage)
	s.mux.HandleFunc("POST /emby/Items/{itemId}/Images/{type}/{index}", s.handleUploadImage)
	s.mux.HandleFunc("DELETE /emby/Items/{itemId}/Images/{type}/{index}", s.handleDeleteImage)

	// 整库批量生成海报/封面（媒体库管理页）
	s.mux.HandleFunc("POST /emby/ArtworkJobs", s.handleCreateArtworkJob)
	s.mux.HandleFunc("GET /emby/ArtworkJobs/{jobId}", s.handleArtworkJob)
	s.mux.HandleFunc("POST /emby/ArtworkJobs/{jobId}/Cancel", s.handleCancelArtworkJob)

	// 进度条缩略图预生成（设置页）
	s.mux.HandleFunc("POST /emby/ThumbnailJobs", s.handleCreateThumbnailJob)
	s.mux.HandleFunc("GET /emby/ThumbnailJobs", s.handleThumbnailJobs)
	s.mux.HandleFunc("GET /emby/ThumbnailJobs/{jobId}", s.handleThumbnailJob)
	s.mux.HandleFunc("POST /emby/ThumbnailJobs/{jobId}/Cancel", s.handleCancelThumbnailJob)

	// 播放
	s.mux.HandleFunc("POST /emby/Items/{itemId}/PlaybackInfo", s.handlePlaybackInfo)
	s.mux.HandleFunc("GET /emby/Videos/{itemId}/stream", s.handleStream)
	s.mux.HandleFunc("GET /emby/Videos/{itemId}/index.bif", s.handleBif)
	s.mux.HandleFunc("POST /emby/Sessions/Playing", s.handleSessionStarted)
	s.mux.HandleFunc("POST /emby/Sessions/Playing/Progress", s.handleSessionProgress)
	s.mux.HandleFunc("POST /emby/Sessions/Playing/Stopped", s.handleSessionStopped)

	// 收藏
	s.mux.HandleFunc("POST /emby/Users/{userId}/FavoriteItems/{itemId}", s.handleSetFavorite(true))
	s.mux.HandleFunc("DELETE /emby/Users/{userId}/FavoriteItems/{itemId}", s.handleSetFavorite(false))

	// 已看 / 未看
	s.mux.HandleFunc("POST /emby/Users/{userId}/PlayedItems/{itemId}", s.handleSetPlayed(true))
	s.mux.HandleFunc("DELETE /emby/Users/{userId}/PlayedItems/{itemId}", s.handleSetPlayed(false))
}
