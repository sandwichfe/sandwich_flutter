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
`
