package httpapi

import (
	"context"
	"log"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

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

// statusRecorder 记录响应状态码、字节数与已鉴权用户，供访问日志使用。
type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int64
	user   string
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(data []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	n, err := r.ResponseWriter.Write(data)
	r.bytes += int64(n)
	return n, err
}

// Flush 透传给底层连接，视频流依赖分块写出与及时 flush。
func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// slowThreshold 超过该耗时的请求单独打标，用于定位列表/图片这类慢接口。
const slowThreshold = 500 * time.Millisecond

// withAccessLog 打印每个请求的方法、路径、状态、耗时与用户。
// 只记录路径不记录 query，避免 api_key 之类的凭据进入日志文件。
func (s *Server) withAccessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := &statusRecorder{ResponseWriter: w}
		start := time.Now()
		next.ServeHTTP(recorder, r)

		if recorder.status == 0 {
			recorder.status = http.StatusOK
		}
		elapsed := time.Since(start)

		// 图片与视频流一次列表滚动就会产生几十个请求，成功且不慢时不记录，避免日志被刷满。
		if elapsed < slowThreshold && recorder.status < http.StatusBadRequest && isMediaRequest(r.URL.Path) {
			return
		}

		user := recorder.user
		if user == "" {
			user = "-"
		}
		if elapsed >= slowThreshold {
			log.Printf("[慢请求] %s %s %d %dms %dB user=%s",
				r.Method, r.URL.Path, recorder.status, elapsed.Milliseconds(), recorder.bytes, user)
			return
		}
		log.Printf("%s %s %d %dms %dB user=%s",
			r.Method, r.URL.Path, recorder.status, elapsed.Milliseconds(), recorder.bytes, user)
	})
}

// isMediaRequest 判断是否为图片/视频流这类高频二进制请求。
func isMediaRequest(path string) bool {
	return strings.HasPrefix(path, "/emby/Videos/") || strings.Contains(path, "/Images/")
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

		// 访问日志中间件在外层，这里把用户名回填给它，避免再加一层中间件。
		if recorder, ok := w.(*statusRecorder); ok {
			recorder.user = user.Name
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
