package httpapi

import (
	"net/http"

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

	mux *http.ServeMux
}

func New(cfg config.Config, st *store.Store, images *media.ImageStore, bif *media.BifCache, scanner *media.Scanner) *Server {
	server := &Server{
		cfg:     cfg,
		store:   st,
		images:  images,
		bif:     bif,
		scanner: scanner,
		mux:     http.NewServeMux(),
	}
	server.routes()
	return server
}

func (s *Server) Handler() http.Handler {
	return s.withRecover(s.withCORS(s.withAuth(s.mux)))
}

func (s *Server) routes() {
	// 认证与系统信息
	s.mux.HandleFunc("POST /emby/Users/AuthenticateByName", s.handleAuthenticate)
	s.mux.HandleFunc("GET /emby/System/Info/Public", s.handlePublicInfo)

	// 用户与头像
	s.mux.HandleFunc("GET /emby/Users/{userId}/Images/Primary", s.handleUserAvatar)
	s.mux.HandleFunc("POST /emby/Users/{userId}/Images/Primary", s.handleUploadUserAvatar)

	// 媒体库
	s.mux.HandleFunc("GET /emby/Users/{userId}/Views", s.handleViews)
	s.mux.HandleFunc("POST /emby/Library/Refresh", s.handleLibraryRefresh)

	// 条目查询
	s.mux.HandleFunc("GET /emby/Users/{userId}/Items", s.handleItems)
	s.mux.HandleFunc("GET /emby/Users/{userId}/Items/Resume", s.handleResume)
	s.mux.HandleFunc("GET /emby/Users/{userId}/Items/{itemId}", s.handleItemDetail)
	s.mux.HandleFunc("GET /emby/Persons", s.handlePersons)
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Similar", s.handleSimilar)
	s.mux.HandleFunc("POST /emby/Items/{itemId}", s.handleUpdateItem)
	s.mux.HandleFunc("POST /emby/Items/{itemId}/Refresh", s.handleRefreshItem)

	// 图片
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Images", s.handleListImages)
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Images/{type}", s.handleImage)
	s.mux.HandleFunc("GET /emby/Items/{itemId}/Images/{type}/{index}", s.handleImage)
	s.mux.HandleFunc("POST /emby/Items/{itemId}/Images/{type}", s.handleUploadImage)
	s.mux.HandleFunc("POST /emby/Items/{itemId}/Images/{type}/{index}", s.handleUploadImage)
	s.mux.HandleFunc("DELETE /emby/Items/{itemId}/Images/{type}/{index}", s.handleDeleteImage)

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
}
