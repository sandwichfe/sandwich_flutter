package config

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
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
	FFprobePath   string
	FFmpegPath    string
	AdminUser     string
	AdminPassword string
	TokenTTL      time.Duration

	// 缓存回收（S4.1）：data/cache 下图片与 BIF 缓存的总量上限与巡检间隔。
	// 上限为 0 表示不按容量淘汰，只清理孤儿文件。
	CacheImageLimitMB  int
	CacheBifLimitMB    int
	CacheSweepInterval time.Duration

	// TMDB 演员刮削：只在手动触发时联网，扫描流程不依赖网络。
	// APIKey 为空时刮削接口直接返回"未配置"，其余功能不受影响。
	TmdbAPIKey   string
	TmdbLanguage string
	TmdbProxy    string
	// TmdbRateLimit 是每秒请求上限，默认 4（TMDB 官方要求不超过 50/秒）。
	TmdbRateLimit    int
	TmdbMaxBackdrops int

	// AV 女优档案站（MinnanoAV / JavDatabase / JavModel / JavDB）。
	// 只在手动触发演员刮削时联网；默认开启，关掉后只走 TMDB。
	JavEnabled   bool
	JavProxy     string
	JavRateLimit int
	JavUserAgent string

	// ConfigPath 记录实际使用的配置文件位置，便于启动日志提示。
	ConfigPath string
}

// fileConfig 是 YAML 文件的映射结构，只负责读，不做业务判断。
type fileConfig struct {
	Server struct {
		Addr    string `yaml:"addr"`
		DataDir string `yaml:"data_dir"`
	} `yaml:"server"`
	Account struct {
		AdminUser     string `yaml:"admin_user"`
		AdminPassword string `yaml:"admin_password"`
	} `yaml:"account"`
	FFmpeg struct {
		FFprobe string `yaml:"ffprobe"`
		FFmpeg  string `yaml:"ffmpeg"`
	} `yaml:"ffmpeg"`
	TokenTTL string `yaml:"token_ttl"`
	Cache    struct {
		// 用指针区分「没写」与「显式写 0」：0 表示关闭容量淘汰。
		ImageLimitMB *int   `yaml:"image_limit_mb"`
		BifLimitMB   *int   `yaml:"bif_limit_mb"`
		Sweep        string `yaml:"sweep_interval"`
	} `yaml:"cache"`
	Tmdb struct {
		APIKey       string `yaml:"api_key"`
		Language     string `yaml:"language"`
		Proxy        string `yaml:"proxy"`
		RateLimit    *int   `yaml:"rate_limit"`
		MaxBackdrops *int   `yaml:"max_backdrops"`
	} `yaml:"tmdb"`
	Jav struct {
		// Enabled 用指针区分「没写」与「显式关掉」，默认 true。
		Enabled   *bool  `yaml:"enabled"`
		Proxy     string `yaml:"proxy"`
		RateLimit *int   `yaml:"rate_limit"`
		UserAgent string `yaml:"user_agent"`
	} `yaml:"jav"`
}

// DefaultAdminPassword 是内置的初始管理员密码，仅用于提示"还没改密码"。
const DefaultAdminPassword = "admin"

func Default() Config {
	return Config{
		Addr:               ":8096",
		DataDir:            "./data",
		FFprobePath:        "ffprobe",
		FFmpegPath:         "ffmpeg",
		AdminUser:          "admin",
		AdminPassword:      DefaultAdminPassword,
		TokenTTL:           30 * 24 * time.Hour,
		CacheImageLimitMB:  2048,
		CacheBifLimitMB:    1024,
		CacheSweepInterval: 6 * time.Hour,
		TmdbLanguage:       "zh-CN",
		TmdbRateLimit:      4,
		TmdbMaxBackdrops:   6,
		JavEnabled:         true,
		JavRateLimit:       1,
	}
}

// Load 读取配置。explicitPath 来自 -config 参数，为空时回退到 EMBYX_CONFIG 与 ./config.yaml。
func Load(explicitPath string) (Config, error) {
	cfg := Default()
	path, explicit := resolveConfigPath(explicitPath)
	// 记录绝对路径：IDE 调试与命令行的工作目录可能不同，相对路径的日志看不出实际读的是哪份。
	if abs, err := filepath.Abs(path); err == nil {
		path = abs
	}
	cfg.ConfigPath = path

	fileCfg, err := loadFile(path, explicit)
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

// resolveConfigPath 返回配置文件路径，以及该路径是否由用户显式指定。
func resolveConfigPath(explicit string) (string, bool) {
	if value := strings.TrimSpace(explicit); value != "" {
		return value, true
	}
	if value := strings.TrimSpace(os.Getenv("EMBYX_CONFIG")); value != "" {
		return value, true
	}
	// 找不到 ./config.yaml 时向上一级查找：IDE 与命令行的工作目录经常不是同一个目录。
	if dir, err := os.Getwd(); err == nil {
		for {
			candidate := filepath.Join(dir, defaultConfigName)
			if _, statErr := os.Stat(candidate); statErr == nil {
				return candidate, false
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return defaultConfigName, false
}

func loadFile(path string, explicit bool) (fileConfig, error) {
	var cfg fileConfig

	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		// 用户显式指定的路径写错了就报错，不在意外目录凭空生成配置。
		if explicit {
			return cfg, fmt.Errorf("配置文件不存在: %s（由 -config 或 EMBYX_CONFIG 指定，不会自动创建）", path)
		}
		// 只在"双击运行"（工作目录就是程序目录）时生成模板。
		// IDE 调试的工作目录往往是项目根，在那里生成默认配置会让人误以为读的是另一份配置。
		if !cwdIsExecutableDir() {
			return cfg, fmt.Errorf(
				"未找到配置文件 %s（当前工作目录 %s，程序目录 %s）；"+
					"请用 -config / EMBYX_CONFIG 指定，或把 IDE 的工作目录设为配置文件所在目录",
				path, cwdOrUnknown(), exeDirOrUnknown(),
			)
		}
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
  ffmpeg:
    ffprobe: 'D:\ffmpeg\bin\ffprobe.exe'   # 单引号，推荐
    ffmpeg: "D:/ffmpeg/bin/ffmpeg.exe"     # 正斜杠`

func (c *Config) applyFile(fc fileConfig) {
	if value := strings.TrimSpace(fc.Server.Addr); value != "" {
		c.Addr = value
	}
	if value := strings.TrimSpace(fc.Server.DataDir); value != "" {
		c.DataDir = value
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
	// 缓存上限允许写 0（关闭容量淘汰），所以只在出现负值时回落默认值。
	if fc.Cache.ImageLimitMB != nil && *fc.Cache.ImageLimitMB >= 0 {
		c.CacheImageLimitMB = *fc.Cache.ImageLimitMB
	}
	if fc.Cache.BifLimitMB != nil && *fc.Cache.BifLimitMB >= 0 {
		c.CacheBifLimitMB = *fc.Cache.BifLimitMB
	}
	if value := strings.TrimSpace(fc.Cache.Sweep); value != "" {
		interval, err := time.ParseDuration(value)
		if err != nil {
			log.Printf("cache.sweep_interval 格式无效（示例 6h），保持默认值: %q", value)
		} else if interval > 0 {
			c.CacheSweepInterval = interval
		}
	}
	if value := strings.TrimSpace(fc.Tmdb.APIKey); value != "" {
		c.TmdbAPIKey = value
	}
	if value := strings.TrimSpace(fc.Tmdb.Language); value != "" {
		c.TmdbLanguage = value
	}
	if value := strings.TrimSpace(fc.Tmdb.Proxy); value != "" {
		c.TmdbProxy = value
	}
	// 允许写 0（不下载写真），只有负数才回落默认值。
	if fc.Tmdb.MaxBackdrops != nil && *fc.Tmdb.MaxBackdrops >= 0 {
		c.TmdbMaxBackdrops = *fc.Tmdb.MaxBackdrops
	}
	// 限流留一点余量：低于 1 或高于 10 都夹到边界，避免手写配置把 Key 打废。
	if fc.Tmdb.RateLimit != nil {
		c.TmdbRateLimit = clamp(*fc.Tmdb.RateLimit, 1, 10)
	}
	if fc.Jav.Enabled != nil {
		c.JavEnabled = *fc.Jav.Enabled
	}
	if value := strings.TrimSpace(fc.Jav.Proxy); value != "" {
		c.JavProxy = value
	}
	if fc.Jav.RateLimit != nil {
		// 档案站都是个人维护的小站，速率上限压到 5 次/秒以内。
		c.JavRateLimit = clamp(*fc.Jav.RateLimit, 1, 5)
	}
	if value := strings.TrimSpace(fc.Jav.UserAgent); value != "" {
		c.JavUserAgent = value
	}
}

func (c *Config) applyEnv() {
	if value := lookupEnv("EMBYX_ADDR"); value != "" {
		c.Addr = value
	}
	if value := lookupEnv("EMBYX_DATA_DIR"); value != "" {
		c.DataDir = value
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
	if value := lookupEnv("EMBYX_TMDB_API_KEY"); value != "" {
		c.TmdbAPIKey = value
	}
	if value := lookupEnv("EMBYX_TMDB_LANGUAGE"); value != "" {
		c.TmdbLanguage = value
	}
	if value := lookupEnv("EMBYX_TMDB_PROXY"); value != "" {
		c.TmdbProxy = value
	}
	if value := lookupEnv("EMBYX_TMDB_RATE_LIMIT"); value != "" {
		if limit, err := strconv.Atoi(value); err == nil {
			c.TmdbRateLimit = clamp(limit, 1, 10)
		} else {
			log.Printf("EMBYX_TMDB_RATE_LIMIT 不是整数（示例 4），保持默认值: %q", value)
		}
	}
	if value := lookupEnv("EMBYX_JAV_ENABLED"); value != "" {
		c.JavEnabled = !strings.EqualFold(value, "false") && value != "0"
	}
	if value := lookupEnv("EMBYX_JAV_PROXY"); value != "" {
		c.JavProxy = value
	}
}

// finalize 归一化数据目录并创建所需子目录。
func (c *Config) finalize() error {
	abs, err := resolveDataDir(c.ConfigPath, c.DataDir)
	if err != nil {
		return fmt.Errorf("解析数据目录失败: %w", err)
	}
	c.DataDir = abs

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

// resolveDataDir 让相对的数据目录基于配置文件所在目录解析。
// 这样 IDE 调试与命令行启动（工作目录不同）也会落到同一份数据库上。
func resolveDataDir(configPath, dataDir string) (string, error) {
	if filepath.IsAbs(dataDir) {
		return filepath.Clean(dataDir), nil
	}
	base := filepath.Dir(configPath)
	if !filepath.IsAbs(base) {
		abs, err := filepath.Abs(base)
		if err != nil {
			return "", err
		}
		base = abs
	}
	return filepath.Abs(filepath.Join(base, dataDir))
}

// cwdIsExecutableDir 判断当前工作目录是否就是程序所在目录（双击启动的典型情况）。
func cwdIsExecutableDir() bool {
	wd, err := os.Getwd()
	if err != nil {
		return false
	}
	dir, err := exeDir()
	if err != nil {
		return false
	}
	return strings.EqualFold(filepath.Clean(wd), filepath.Clean(dir))
}

func exeDir() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(executable), nil
}

func cwdOrUnknown() string {
	if wd, err := os.Getwd(); err == nil {
		return wd
	}
	return "未知"
}

func exeDirOrUnknown() string {
	if dir, err := exeDir(); err == nil {
		return dir
	}
	return "未知"
}

func lookupEnv(key string) string {
	return strings.TrimSpace(os.Getenv(key))
}

// clamp 把 value 限制在 [low, high] 区间内。
func clamp(value, low, high int) int {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

const defaultConfigTemplate = `# embyx 配置文件
# 修改后重启服务生效。
# 环境变量（EMBYX_ADDR / EMBYX_DATA_DIR / EMBYX_ADMIN_PASSWORD ...）
# 优先级高于本文件，可用于临时覆盖。

server:
  # 监听地址；":8096" 表示监听所有网卡的 8096 端口
  addr: ":8096"
  # 数据库、图片、缓存目录；相对路径基于本配置文件所在目录
  data_dir: "./data"

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

cache:
  # 缩放图片缓存总量上限（MB）；超出后按最久未使用淘汰，0 表示不限制
  image_limit_mb: 2048
  # 进度条缩略图（BIF）缓存总量上限（MB），0 表示不限制
  bif_limit_mb: 1024
  # 缓存巡检间隔（Go duration 格式）：清理已删除条目的残留文件并执行容量淘汰
  sweep_interval: 6h

# 演员刮削（TMDB）。仅在设置页/人物页手动触发，扫描流程不联网。
# API Key 在 https://www.themoviedb.org/settings/api 免费申请。
tmdb:
  api_key: ''
  # 简介优先取该语言，为空时回退 en-US
  language: zh-CN
  # 国内网络通常需要代理，例如 http://127.0.0.1:7890
  proxy: ''
  # 每秒请求上限（1~10）。官方要求不超过 50/秒，默认 4 留足余量
  rate_limit: 4
  # 每位演员最多保存多少张写真（0 表示不下载写真）
  max_backdrops: 6

# AV 女优档案来源（MinnanoAV / JavDatabase / JavModel / JavDB）。
# 仅在手动触发演员刮削时联网，与影片刮削无关。
jav:
  # 关掉后演员刮削只走 TMDB
  enabled: true
  # 这些站点国内通常也需要代理
  proxy: ''
  # 每个站点每秒请求上限（1~5），小站建议保持 1
  rate_limit: 1
  # 留空使用内置浏览器 UA；被 Cloudflare 拦截时可换成自己的
  user_agent: ''
`
