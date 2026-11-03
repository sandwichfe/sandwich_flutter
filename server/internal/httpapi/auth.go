package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

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

func (s *Server) handleUserAvatar(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	raw, err := s.images.LoadUserAvatar(userID)
	if err != nil {
		writeError(w, http.StatusNotFound, "头像不存在")
		return
	}
	rendered, err := media.Render(raw, atoi(r.URL.Query().Get("MaxWidth")), atoi(r.URL.Query().Get("Quality")))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "渲染头像失败")
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
