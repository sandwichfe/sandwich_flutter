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

func (s *Store) UserByToken(token string) (*User, error) {
	if token == "" {
		return nil, ErrNotFound
	}
	return s.scanUser(s.db.QueryRow(
		`SELECT u.id, u.name, u.password_hash, u.is_admin, u.primary_image_tag, u.created_at
		 FROM users u JOIN tokens t ON t.user_id = u.id WHERE t.token = ?`, token,
	))
}

func (s *Store) DeleteToken(token string) error {
	_, err := s.db.Exec(`DELETE FROM tokens WHERE token = ?`, token)
	return err
}

func (s *Store) UpdateUserImageTag(userID, tag string) error {
	_, err := s.db.Exec(`UPDATE users SET primary_image_tag = ? WHERE id = ?`, tag, userID)
	return err
}
