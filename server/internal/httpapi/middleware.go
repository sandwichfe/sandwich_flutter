package httpapi

import (
	"context"
	"log"
	"net/http"
	"runtime/debug"
	"strings"

	"embyx/internal/store"
)

type contextKey string

const userContextKey contextKey = "embyx.user"

// 无需鉴权的路径：登录接口与公开系统信息。
var publicPaths = map[string]bool{
	"/emby/Users/AuthenticateByName": true,
	"/emby/System/Info/Public":       true,
}

func (s *Server) withRecover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				log.Printf("panic: %v\n%s", recovered, debug.Stack())
				writeError(w, http.StatusInternalServerError, "服务器内部错误")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// withAuth 同时接受 X-Emby-Token 头与 api_key 查询参数：
// 图片和视频地址由客户端拼成普通 URL，只能带 query 鉴权。
func (s *Server) withAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if publicPaths[r.URL.Path] {
			next.ServeHTTP(w, r)
			return
		}

		token := tokenFromRequest(r)
		if token == "" {
			writeError(w, http.StatusUnauthorized, "缺少访问令牌")
			return
		}
		user, err := s.store.UserByToken(token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "登录已失效，请重新登录")
			return
		}

		ctx := context.WithValue(r.Context(), userContextKey, user)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func currentUser(r *http.Request) *store.User {
	user, _ := r.Context().Value(userContextKey).(*store.User)
	return user
}

func tokenFromRequest(r *http.Request) string {
	if value := r.Header.Get("X-Emby-Token"); value != "" {
		return value
	}
	if value := r.Header.Get("X-MediaBrowser-Token"); value != "" {
		return value
	}
	if value := r.URL.Query().Get("api_key"); value != "" {
		return value
	}
	if value := r.URL.Query().Get("ApiKey"); value != "" {
		return value
	}
	if value := r.Header.Get("Authorization"); strings.HasPrefix(value, "MediaBrowser") {
		if extracted := extractQuoted(value, "Token"); extracted != "" {
			return extracted
		}
	}
	return ""
}

func extractQuoted(header, key string) string {
	marker := key + `="`
	index := strings.Index(header, marker)
	if index < 0 {
		return ""
	}
	rest := header[index+len(marker):]
	if end := strings.Index(rest, `"`); end >= 0 {
		return rest[:end]
	}
	return ""
}
