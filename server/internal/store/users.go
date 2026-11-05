package store

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
)

var ErrNotFound = errors.New("记录不存在")

type User struct {
	ID              string
	Name            string
	PasswordHash    string
	IsAdmin         bool
	PrimaryImageTag string
	CreatedAt       string
}

func HashPassword(password string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	digest := hashWithSalt(salt, password)
	return "sha256$" + hex.EncodeToString(salt) + "$" + hex.EncodeToString(digest)
}

func VerifyPassword(encoded, password string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 3 || parts[0] != "sha256" {
		return false
	}
	salt, err := hex.DecodeString(parts[1])
	if err != nil {
		return false
	}
	expected, err := hex.DecodeString(parts[2])
	if err != nil {
		return false
	}
	actual := hashWithSalt(salt, password)
	return subtle.ConstantTimeCompare(expected, actual) == 1
}

func hashWithSalt(salt []byte, password string) []byte {
	buf := make([]byte, 0, len(salt)+len(password))
	buf = append(buf, salt...)
	buf = append(buf, password...)
	sum := sha256.Sum256(buf)
	return sum[:]
}

// EnsureAdmin 在首次启动时创建管理员账号，已存在则跳过。
func (s *Store) EnsureAdmin(name, password string) error {
	if _, err := s.UserByName(name); err == nil {
		return nil
	} else if !errors.Is(err, ErrNotFound) {
		return err
	}
	_, err := s.CreateUser(name, password, true)
	return err
}

func (s *Store) CreateUser(name, password string, isAdmin bool) (*User, error) {
	user := &User{
		ID:           NewID(),
		Name:         strings.TrimSpace(name),
		PasswordHash: HashPassword(password),
		IsAdmin:      isAdmin,
		CreatedAt:    NowISO(),
	}
	_, err := s.db.Exec(
		`INSERT INTO users (id, name, password_hash, is_admin, created_at) VALUES (?, ?, ?, ?, ?)`,
		user.ID, user.Name, user.PasswordHash, boolToInt(user.IsAdmin), user.CreatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("创建用户失败: %w", err)
	}
	return user, nil
}

func (s *Store) UserByName(name string) (*User, error) {
	return s.scanUser(s.db.QueryRow(
		`SELECT id, name, password_hash, is_admin, primary_image_tag, created_at
		 FROM users WHERE name = ? COLLATE NOCASE`, strings.TrimSpace(name),
	))
}

func (s *Store) UserByID(id string) (*User, error) {
	return s.scanUser(s.db.QueryRow(
		`SELECT id, name, password_hash, is_admin, primary_image_tag, created_at
		 FROM users WHERE id = ?`, id,
	))
}

func (s *Store) scanUser(row *sql.Row) (*User, error) {
	var user User
	var isAdmin int
	err := row.Scan(&user.ID, &user.Name, &user.PasswordHash, &isAdmin, &user.PrimaryImageTag, &user.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	user.IsAdmin = isAdmin != 0
	return &user, nil
}

func (s *Store) CreateToken(userID string) (string, error) {
	token := NewID() + NewID()
	_, err := s.db.Exec(
		`INSERT INTO tokens (token, user_id, created_at) VALUES (?, ?, ?)`,
		token, userID, NowISO(),
	)
	if err != nil {
		return "", fmt.Errorf("签发令牌失败: %w", err)
	}
	return token, nil
}

// tokenCacheTTL 是令牌解析结果的缓存时长。
// 图片列表一屏就是几十个请求，每个请求都查一次 tokens JOIN users 是纯浪费；
// 登出与清理过期令牌时都会主动失效，最长 1 分钟自动对齐。
const tokenCacheTTL = time.Minute

// tokenCacheEntry 缓存一个令牌解析出的用户，以及（可选的）令牌过期时刻。
type tokenCacheEntry struct {
	user      *User
	expiresAt time.Time
}

// UserByToken 按令牌查用户。notBefore 非零时只接受签发时间不早于它的令牌，
// 让配置里的 token_ttl 真正生效（否则令牌一旦签发就永久有效）。
func (s *Store) UserByToken(token string, notBefore time.Time) (*User, error) {
	if token == "" {
		return nil, ErrNotFound
	}

	now := time.Now()
	s.tokenMu.Lock()
	entry, cached := s.tokenCache[token]
	s.tokenMu.Unlock()
	if cached && now.Before(entry.expiresAt) {
		return entry.user, nil
	}

	// 多取一列 t.created_at：缓存的过期时刻必须早于令牌自身的过期时刻。
	query := `SELECT u.id, u.name, u.password_hash, u.is_admin, u.primary_image_tag, u.created_at, t.created_at
		 FROM users u JOIN tokens t ON t.user_id = u.id WHERE t.token = ?`
	args := []any{token}
	if !notBefore.IsZero() {
		// created_at 是定宽的 UTC 时间串，字符串比较即时间先后比较。
		query += ` AND t.created_at >= ?`
		args = append(args, isoTime(notBefore))
	}

	var (
		user           User
		isAdmin        int
		tokenCreatedAt string
	)
	err := s.db.QueryRow(query, args...).Scan(
		&user.ID, &user.Name, &user.PasswordHash, &isAdmin,
		&user.PrimaryImageTag, &user.CreatedAt, &tokenCreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	user.IsAdmin = isAdmin != 0

	expiresAt := now.Add(tokenCacheTTL)
	if !notBefore.IsZero() {
		if createdAt, parseErr := time.Parse(isoLayout, tokenCreatedAt); parseErr == nil {
			// 令牌在 created_at + ttl 之后失效，缓存不能活得比它更久。
			if tokenExpiry := createdAt.Add(now.Sub(notBefore)); tokenExpiry.Before(expiresAt) {
				expiresAt = tokenExpiry
			}
		}
	}
	if now.Before(expiresAt) {
		s.tokenMu.Lock()
		if s.tokenCache == nil {
			s.tokenCache = make(map[string]tokenCacheEntry)
		}
		s.tokenCache[token] = tokenCacheEntry{user: &user, expiresAt: expiresAt}
		s.tokenMu.Unlock()
	}
	return &user, nil
}

func (s *Store) DeleteToken(token string) error {
	if _, err := s.db.Exec(`DELETE FROM tokens WHERE token = ?`, token); err != nil {
		return err
	}
	// 立即失效：登出后不能靠缓存继续放行。
	s.tokenMu.Lock()
	delete(s.tokenCache, token)
	s.tokenMu.Unlock()
	return nil
}

// DeleteTokensBefore 删除某用户签发时间早于 before 的令牌，登录时顺手清理过期记录。
func (s *Store) DeleteTokensBefore(userID string, before time.Time) error {
	if _, err := s.db.Exec(`DELETE FROM tokens WHERE user_id = ? AND created_at < ?`,
		userID, isoTime(before)); err != nil {
		return err
	}
	// 受影响令牌可能已被缓存：清空整表最省事，登录是低频操作。
	s.tokenMu.Lock()
	s.tokenCache = nil
	s.tokenMu.Unlock()
	return nil
}

func (s *Store) UpdateUserImageTag(userID, tag string) error {
	_, err := s.db.Exec(`UPDATE users SET primary_image_tag = ? WHERE id = ?`, tag, userID)
	return err
}
