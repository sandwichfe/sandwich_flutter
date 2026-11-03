package config

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

const defaultConfigName = "config.yaml"

// Config 是运行期配置。
// 优先级：环境变量 > 配置文件 > 内置默认值。
type Config struct {
	Addr          string
	DataDir       string
	MediaRoots    []string
	FFprobePath   string
	FFmpegPath    string
	AdminUser     string
	AdminPassword string
	TokenTTL      time.Duration

	// ConfigPath 记录实际使用的配置文件位置，便于启动日志提示。
	ConfigPath string
}

// fileConfig 是 YAML 文件的映射结构，只负责读，不做业务判断。
type fileConfig struct {
	Server struct {
		Addr    string `yaml:"addr"`
		DataDir string `yaml:"data_dir"`
	} `yaml:"server"`
	Library struct {
		Roots []string `yaml:"roots"`
	} `yaml:"library"`
	Account struct {
		AdminUser     string `yaml:"admin_user"`
		AdminPassword string `yaml:"admin_password"`
	} `yaml:"account"`
	FFmpeg struct {
		FFprobe string `yaml:"ffprobe"`
		FFmpeg  string `yaml:"ffmpeg"`
	} `yaml:"ffmpeg"`
	TokenTTL string `yaml:"token_ttl"`
}

func Default() Config {
	return Config{
		Addr:          ":8096",
		DataDir:       "./data",
		FFprobePath:   "ffprobe",
		FFmpegPath:    "ffmpeg",
		AdminUser:     "admin",
		AdminPassword: "admin",
		TokenTTL:      30 * 24 * time.Hour,
	}
}

// Load 读取配置。explicitPath 来自 -config 参数，为空时回退到 EMBYX_CONFIG 与 ./config.yaml。
func Load(explicitPath string) (Config, error) {
	cfg := Default()
	path := resolveConfigPath(explicitPath)
	cfg.ConfigPath = path

	fileCfg, err := loadFile(path)
	if err != nil {
		return cfg, err
	}
	cfg.applyFile(fileCfg)
	cfg.applyEnv()

	if err := cfg.finalize(); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func resolveConfigPath(explicit string) string {
	if value := strings.TrimSpace(explicit); value != "" {
		return value
	}
	if value := strings.TrimSpace(os.Getenv("EMBYX_CONFIG")); value != "" {
		return value
	}
	return defaultConfigName
}

func loadFile(path string) (fileConfig, error) {
	var cfg fileConfig

	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		// 首次启动生成一份可直接修改的模板，避免用户从零拼装。
		if writeErr := os.WriteFile(path, []byte(defaultConfigTemplate), 0o644); writeErr != nil {
			log.Printf("无法生成默认配置文件 %s: %v", path, writeErr)
		} else {
			log.Printf("已生成默认配置文件: %s", path)
		}
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("读取配置文件失败: %w", err)
	}

	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return cfg, fmt.Errorf("解析配置文件 %s 失败: %w%s", path, err, yamlPathHint)
	}
	return cfg, nil
}

// yamlPathHint 针对最常见的"Windows 路径写进双引号"给出可直接照抄的写法。
const yamlPathHint = `
提示：路径请用单引号包裹，或改用正斜杠。双引号里的反斜杠会被 YAML 当作转义符：
  roots:
    - 'D:\Media\电影'                      # 单引号，推荐
    - "D:/Media/电影"                      # 正斜杠
    - '\\192.168.1.10\share\movies'        # UNC 网络路径必须用单引号`

func (c *Config) applyFile(fc fileConfig) {
	if value := strings.TrimSpace(fc.Server.Addr); value != "" {
		c.Addr = value
	}
	if value := strings.TrimSpace(fc.Server.DataDir); value != "" {
		c.DataDir = value
	}
	if len(fc.Library.Roots) > 0 {
		c.MediaRoots = normalizeRootList(fc.Library.Roots)
	}
	if value := strings.TrimSpace(fc.Account.AdminUser); value != "" {
		c.AdminUser = value
	}
	if value := strings.TrimSpace(fc.Account.AdminPassword); value != "" {
		c.AdminPassword = value
	}
	if value := strings.TrimSpace(fc.FFmpeg.FFprobe); value != "" {
		c.FFprobePath = value
	}
	if value := strings.TrimSpace(fc.FFmpeg.FFmpeg); value != "" {
		c.FFmpegPath = value
	}
	if value := strings.TrimSpace(fc.TokenTTL); value != "" {
		ttl, err := time.ParseDuration(value)
		if err != nil {
			log.Printf("token_ttl 格式无效（示例 720h），保持默认值: %q", value)
		} else {
			c.TokenTTL = ttl
		}
	}
}

func (c *Config) applyEnv() {
	if value := lookupEnv("EMBYX_ADDR"); value != "" {
		c.Addr = value
	}
	if value := lookupEnv("EMBYX_DATA_DIR"); value != "" {
		c.DataDir = value
	}
	if value := lookupEnv("EMBYX_MEDIA_ROOTS"); value != "" {
		c.MediaRoots = splitRootString(value)
	}
	if value := lookupEnv("EMBYX_ADMIN_USER"); value != "" {
		c.AdminUser = value
	}
	if value := lookupEnv("EMBYX_ADMIN_PASSWORD"); value != "" {
		c.AdminPassword = value
	}
	if value := lookupEnv("EMBYX_FFPROBE"); value != "" {
		c.FFprobePath = value
	}
	if value := lookupEnv("EMBYX_FFMPEG"); value != "" {
		c.FFmpegPath = value
	}
}

// finalize 归一化路径、过滤不存在的媒体目录、创建数据目录。
func (c *Config) finalize() error {
	abs, err := filepath.Abs(c.DataDir)
	if err != nil {
		return fmt.Errorf("解析数据目录失败: %w", err)
	}
	c.DataDir = abs

	roots := make([]string, 0, len(c.MediaRoots))
	for _, root := range c.MediaRoots {
		absRoot, err := filepath.Abs(root)
		if err != nil {
			log.Printf("媒体目录路径无效，已跳过: %s", root)
			continue
		}
		info, err := os.Stat(absRoot)
		if err != nil || !info.IsDir() {
			log.Printf("媒体目录不存在，已跳过: %s", absRoot)
			continue
		}
		roots = append(roots, absRoot)
	}
	c.MediaRoots = roots

	for _, dir := range []string{
		c.DataDir,
		filepath.Join(c.DataDir, "images"),
		filepath.Join(c.DataDir, "users"),
		filepath.Join(c.DataDir, "cache", "bif"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("创建目录 %s 失败: %w", dir, err)
		}
	}
	return nil
}

// normalizeRootList 处理 YAML 列表：去空白、去包裹引号，不做分隔符切分
// （目录名本身可能包含逗号或分号）。
func normalizeRootList(values []string) []string {
	seen := make(map[string]bool, len(values))
	roots := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		roots = append(roots, value)
	}
	return roots
}

// splitRootString 解析环境变量里的多目录写法（分号或逗号分隔）。
func splitRootString(value string) []string {
	parts := strings.FieldsFunc(value, func(r rune) bool {
		return r == ';' || r == ','
	})
	return normalizeRootList(parts)
}

func lookupEnv(key string) string {
	return strings.TrimSpace(os.Getenv(key))
}

const defaultConfigTemplate = `# embyx 配置文件
# 修改后重启服务生效。
# 环境变量（EMBYX_ADDR / EMBYX_MEDIA_ROOTS / EMBYX_ADMIN_PASSWORD ...）
# 优先级高于本文件，可用于临时覆盖。

server:
  # 监听地址；":8096" 表示监听所有网卡的 8096 端口
  addr: ":8096"
  # 数据库、图片、缓存目录；相对路径基于启动时的工作目录
  data_dir: "./data"

library:
  # 每个目录会生成一个媒体库，库名取目录名，子目录递归扫描。
  # 路径建议用正斜杠，或用单引号包裹，避免 YAML 把反斜杠当转义符：
  #   - 'D:\Media\电影'
  roots: []
  # 示例：
  # roots:
  #   - "D:/Media/电影"
  #   - "D:/Media/剧集"

account:
  # 仅在账号不存在时用于创建管理员；已存在的账号不会被这里覆盖
  admin_user: admin
  admin_password: admin

ffmpeg:
  # 不在 PATH 中时填写绝对路径
  ffprobe: ffprobe
  ffmpeg: ffmpeg

# 登录令牌有效期（Go duration 格式），预留项
token_ttl: 720h
`
