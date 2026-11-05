package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"embyx/internal/dto"
	"embyx/internal/media"
	"embyx/internal/store"
)

const serverID = "embyx-server"

func (s *Server) handleAuthenticate(w http.ResponseWriter, r *http.Request) {
	var payload dto.AuthenticationRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体格式错误")
		return
	}
	username := strings.TrimSpace(payload.Username)
	if username == "" {
		writeError(w, http.StatusUnauthorized, "用户名或密码错误")
		return
	}

	user, err := s.store.UserByName(username)
	if err != nil {
		// 用户不存在与密码错误返回同一状态码，避免账号枚举。
		writeError(w, http.StatusUnauthorized, "用户名或密码错误")
		return
	}
	if !store.VerifyPassword(user.PasswordHash, payload.Pw) {
		writeError(w, http.StatusUnauthorized, "用户名或密码错误")
		return
	}

	token, err := s.store.CreateToken(user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "签发令牌失败")
		return
	}
	// 顺手清掉该用户已过期的令牌：tokens 表原本只增不减。
	if ttl := s.cfg.TokenTTL; ttl > 0 {
		if err := s.store.DeleteTokensBefore(user.ID, time.Now().Add(-ttl)); err != nil {
			log.Printf("清理过期令牌失败 user=%s: %v", user.ID, err)
		}
	}

	writeJSON(w, http.StatusOK, dto.AuthenticationResult{
		User:        toUserDto(user),
		AccessToken: token,
		ServerID:    serverID,
		SessionInfo: &dto.SessionInfo{
			UserID:   user.ID,
			UserName: user.Name,
		},
	})
}

func (s *Server) handlePublicInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ServerName": "embyx",
		"Version":    "0.1.0",
		"Id":         serverID,
	})
}

// handleLogout 让当前令牌立即失效。tokens 表没有过期标记字段，
// 删除是唯一的失效手段；令牌泄露后也就靠这个接口止损。
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if token := tokenFromRequest(r); token != "" {
		if err := s.store.DeleteToken(token); err != nil {
			writeError(w, http.StatusInternalServerError, "退出登录失败")
			return
		}
	}
	writeNoContent(w)
}

func (s *Server) handleUserAvatar(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	raw, err := s.images.LoadUserAvatar(userID)
	if err != nil {
		writeError(w, http.StatusNotFound, "头像不存在")
		return
	}
	// 走 ImageRenderer：人物详情页与演职员列表会反复请求同一张头像，
	// 直连 media.Render 等于每次都解码缩放，既没有磁盘缓存也没有并发控制。
	maxWidth := media.NormalizeRenderWidth(atoi(firstNonEmpty(
		r.URL.Query().Get("maxWidth"), r.URL.Query().Get("MaxWidth"))))
	quality := media.NormalizeRenderQuality(atoi(r.URL.Query().Get("Quality")))
	rendered, tag, err := s.imageRenderer.Render(userID, "Primary", 0, raw, maxWidth, quality)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "渲染头像失败")
		return
	}

	etag := fmt.Sprintf(`"%s-w%d-q%d"`, tag, maxWidth, quality)
	w.Header().Set("ETag", etag)
	if match := r.Header.Get("If-None-Match"); match != "" && match == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(rendered)
}

func (s *Server) handleUploadUserAvatar(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	if !s.canManageUser(r, userID) {
		writeError(w, http.StatusForbidden, "没有权限修改该用户")
		return
	}
	raw, err := readImageBody(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	tag, err := s.images.SaveUserAvatar(userID, raw)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "保存头像失败")
		return
	}
	_ = s.store.UpdateUserImageTag(userID, tag)
	// 换头像后旧的缩放缓存不会再命中，直接清掉，别留到下次巡检。
	s.imageRenderer.RemoveItem(userID)
	// 回传新的主图标记，客户端据此刷新头像地址并解除“无头像”状态。
	w.Header().Set("X-Primary-Image-Tag", tag)
	writeNoContent(w)
}

func (s *Server) canManageUser(r *http.Request, userID string) bool {
	user := currentUser(r)
	if user == nil {
		return false
	}
	return user.IsAdmin || user.ID == userID
}

// readImageBody 兼容 Base64 文本与外发二进制两种上传形式。
func readImageBody(r *http.Request) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	if err != nil {
		return nil, errors.New("读取请求体失败")
	}
	body = bytes.TrimSpace(body)
	if len(body) == 0 {
		return nil, errors.New("图片内容为空")
	}

	compact := strings.Join(strings.Fields(string(body)), "")
	if decoded, err := base64.StdEncoding.DecodeString(compact); err == nil && len(decoded) > 0 {
		return decoded, nil
	}
	return body, nil
}

func toUserDto(user *store.User) *dto.UserDto {
	return &dto.UserDto{
		ID:              user.ID,
		Name:            user.Name,
		ServerID:        serverID,
		HasPassword:     user.PasswordHash != "",
		PrimaryImageTag: user.PrimaryImageTag,
		Policy:          &dto.UserPolicy{IsAdministrator: user.IsAdmin},
	}
}
