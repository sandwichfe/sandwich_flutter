package media

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/draw"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

var ErrImageNotFound = errors.New("图片不存在")

// ImageStore 负责条目图片与用户头像的落盘、读取和按宽度缩放。
type ImageStore struct {
	root string
}

func NewImageStore(root string) *ImageStore {
	return &ImageStore{root: root}
}

// generatedDir 是"服务端从视频画面生成"的图片子目录。
// 与目录导入、手动上传的图片分开存放，客户端可以用 Source 参数在两者之间切换，互不覆盖。
const generatedDir = "generated"

func (s *ImageStore) ItemPath(itemID, imageType string, index int) string {
	return filepath.Join(s.root, sanitizeID(itemID), strings.ToLower(imageType), strconv.Itoa(index)+".jpg")
}

// GeneratedPath 返回生成图片的落盘位置。
func (s *ImageStore) GeneratedPath(itemID, imageType string, index int) string {
	return filepath.Join(s.root, sanitizeID(itemID), generatedDir,
		strings.ToLower(imageType), strconv.Itoa(index)+".jpg")
}

// SaveGeneratedImage 写入服务端生成的图片，规则与上传一致：能解码就统一转成 JPEG。
func (s *ImageStore) SaveGeneratedImage(itemID, imageType string, index int, raw []byte) (string, error) {
	if len(raw) == 0 {
		return "", fmt.Errorf("图片内容为空")
	}
	path := s.GeneratedPath(itemID, imageType, index)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", fmt.Errorf("创建生成图片目录失败: %w", err)
	}
	if normalized, err := transcodeToJPEG(raw, 92); err == nil {
		raw = normalized
	}
	if err := writeFileAtomic(path, raw); err != nil {
		return "", fmt.Errorf("写入生成图片失败: %w", err)
	}
	return hashTag(raw), nil
}

func (s *ImageStore) LoadGeneratedImage(itemID, imageType string, index int) ([]byte, error) {
	return readFileOrNotFound(s.GeneratedPath(itemID, imageType, index))
}

// HasItemImage / HasGeneratedImage 只判断文件是否存在且非空。
// 批量检查缺图时用它们，避免为了确认存在就读整张图。
func (s *ImageStore) HasItemImage(itemID, imageType string, index int) bool {
	return fileExists(s.ItemPath(itemID, imageType, index))
}

func (s *ImageStore) HasGeneratedImage(itemID, imageType string, index int) bool {
	return fileExists(s.GeneratedPath(itemID, imageType, index))
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}

func (s *ImageStore) DeleteGeneratedImage(itemID, imageType string, index int) error {
	err := os.Remove(s.GeneratedPath(itemID, imageType, index))
	if errors.Is(err, os.ErrNotExist) {
		return ErrImageNotFound
	}
	return err
}

func (s *ImageStore) UserAvatarPath(userID string) string {
	return filepath.Join(filepath.Dir(s.root), "users", sanitizeID(userID), "primary.jpg")
}

func (s *ImageStore) SaveItemImage(itemID, imageType string, index int, raw []byte) (string, error) {
	if len(raw) == 0 {
		return "", fmt.Errorf("图片内容为空")
	}
	path := s.ItemPath(itemID, imageType, index)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", fmt.Errorf("创建图片目录失败: %w", err)
	}

	// 有解码能力时统一转成 JPEG，保证后续缩放路径只有一种格式。
	if normalized, err := transcodeToJPEG(raw, 92); err == nil {
		raw = normalized
	}
	if err := writeFileAtomic(path, raw); err != nil {
		return "", fmt.Errorf("写入图片失败: %w", err)
	}
	return hashTag(raw), nil
}

func (s *ImageStore) DeleteItemImage(itemID, imageType string, index int) error {
	err := os.Remove(s.ItemPath(itemID, imageType, index))
	if errors.Is(err, os.ErrNotExist) {
		return ErrImageNotFound
	}
	return err
}

func (s *ImageStore) LoadItemImage(itemID, imageType string, index int) ([]byte, error) {
	return readFileOrNotFound(s.ItemPath(itemID, imageType, index))
}

func (s *ImageStore) SaveUserAvatar(userID string, raw []byte) (string, error) {
	path := s.UserAvatarPath(userID)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", fmt.Errorf("创建头像目录失败: %w", err)
	}
	if normalized, err := transcodeToJPEG(raw, 92); err == nil {
		raw = normalized
	}
	if err := writeFileAtomic(path, raw); err != nil {
		return "", fmt.Errorf("写入头像失败: %w", err)
	}
	return hashTag(raw), nil
}

func (s *ImageStore) LoadUserAvatar(userID string) ([]byte, error) {
	return readFileOrNotFound(s.UserAvatarPath(userID))
}

// RemoveItem 删除某个条目的全部图片，用于媒体库条目被清理时同步回收磁盘。
func (s *ImageStore) RemoveItem(itemID string) error {
	return os.RemoveAll(filepath.Join(s.root, sanitizeID(itemID)))
}

// Render 按客户端传入的最大宽度和画质重新编码，避免原图直出拖垮列表滚动。
func Render(raw []byte, maxWidth int, quality int) ([]byte, error) {
	if quality <= 0 || quality > 100 {
		quality = 82
	}
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		// 无法解码时原样返回，至少保证图片可见。
		return raw, nil
	}
	if maxWidth > 0 && src.Bounds().Dx() > maxWidth {
		ratio := float64(maxWidth) / float64(src.Bounds().Dx())
		height := int(math.Round(float64(src.Bounds().Dy()) * ratio))
		if height < 1 {
			height = 1
		}
		// TODO: 图片量大时换成 libvips(govips)，当前实现是纯 Go 双线性缩放。
		src = resizeBilinear(src, maxWidth, height)
	}

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, src, &jpeg.Options{Quality: quality}); err != nil {
		return nil, fmt.Errorf("编码 JPEG 失败: %w", err)
	}
	return buf.Bytes(), nil
}

func transcodeToJPEG(raw []byte, quality int) ([]byte, error) {
	src, format, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	if format == "jpeg" {
		return raw, nil
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, src, &jpeg.Options{Quality: quality}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func DecodeConfig(raw []byte) (int, int, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return 0, 0, err
	}
	if format == "" {
		return 0, 0, errors.New("未知图片格式")
	}
	return cfg.Width, cfg.Height, nil
}

func resizeBilinear(src image.Image, dstWidth, dstHeight int) *image.RGBA {
	// 先统一转成 *image.RGBA 再按像素切片索引：
	// 逐像素调用 image.Image.At() 的接口开销是这条路径上最大的成本。
	source := toRGBA(src)
	srcWidth, srcHeight := source.Rect.Dx(), source.Rect.Dy()
	dst := image.NewRGBA(image.Rect(0, 0, dstWidth, dstHeight))

	scaleX := float64(srcWidth) / float64(dstWidth)
	scaleY := float64(srcHeight) / float64(dstHeight)

	for dy := 0; dy < dstHeight; dy++ {
		sourceY := (float64(dy)+0.5)*scaleY - 0.5
		y0 := int(math.Floor(sourceY))
		weightY := sourceY - float64(y0)
		if y0 < 0 {
			y0, weightY = 0, 0
		}
		y1 := y0 + 1
		if y1 >= srcHeight {
			y1 = srcHeight - 1
		}
		wy := uint32(weightY * 256)

		row0 := source.Pix[y0*source.Stride:]
		row1 := source.Pix[y1*source.Stride:]
		dstRow := dst.Pix[dy*dst.Stride:]

		for dx := 0; dx < dstWidth; dx++ {
			sourceX := (float64(dx)+0.5)*scaleX - 0.5
			x0 := int(math.Floor(sourceX))
			weightX := sourceX - float64(x0)
			if x0 < 0 {
				x0, weightX = 0, 0
			}
			x1 := x0 + 1
			if x1 >= srcWidth {
				x1 = srcWidth - 1
			}
			wx := uint32(weightX * 256)

			p00 := row0[x0*4:]
			p10 := row0[x1*4:]
			p01 := row1[x0*4:]
			p11 := row1[x1*4:]
			out := dstRow[dx*4:]
			out[0] = blendChannel(p00[0], p10[0], p01[0], p11[0], wx, wy)
			out[1] = blendChannel(p00[1], p10[1], p01[1], p11[1], wx, wy)
			out[2] = blendChannel(p00[2], p10[2], p01[2], p11[2], wx, wy)
			out[3] = blendChannel(p00[3], p10[3], p01[3], p11[3], wx, wy)
		}
	}
	return dst
}

// toRGBA 把任意格式转成 *image.RGBA；本身就是 RGBA 时直接复用，不做拷贝。
func toRGBA(src image.Image) *image.RGBA {
	if rgba, ok := src.(*image.RGBA); ok {
		return rgba
	}
	bounds := src.Bounds()
	dst := image.NewRGBA(image.Rect(0, 0, bounds.Dx(), bounds.Dy()))
	draw.Draw(dst, dst.Bounds(), src, bounds.Min, draw.Src)
	return dst
}

// blendChannel 用 0~256 的定点权值做双线性混合，整数运算明显快于浮点。
func blendChannel(v00, v10, v01, v11 uint8, wx, wy uint32) uint8 {
	top := uint32(v00)*(256-wx) + uint32(v10)*wx
	bottom := uint32(v01)*(256-wx) + uint32(v11)*wx
	return uint8((top*(256-wy) + bottom*wy) >> 16)
}

func hashTag(raw []byte) string {
	sum := sha1.Sum(raw)
	return hex.EncodeToString(sum[:8])
}

func sanitizeID(id string) string {
	cleaned := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		default:
			return -1
		}
	}, id)
	if cleaned == "" {
		return "unknown"
	}
	return cleaned
}

func readFileOrNotFound(path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrImageNotFound
	}
	return raw, err
}
