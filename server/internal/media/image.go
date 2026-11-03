package media

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/color"
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

func (s *ImageStore) ItemPath(itemID, imageType string, index int) string {
	return filepath.Join(s.root, sanitizeID(itemID), strings.ToLower(imageType), strconv.Itoa(index)+".jpg")
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
	if err := os.WriteFile(path, raw, 0o644); err != nil {
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
	if err := os.WriteFile(path, raw, 0o644); err != nil {
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
	bounds := src.Bounds()
	srcWidth, srcHeight := bounds.Dx(), bounds.Dy()
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

			r00, g00, b00, a00 := rgbaAt(src, bounds.Min.X+x0, bounds.Min.Y+y0)
			r10, g10, b10, a10 := rgbaAt(src, bounds.Min.X+x1, bounds.Min.Y+y0)
			r01, g01, b01, a01 := rgbaAt(src, bounds.Min.X+x0, bounds.Min.Y+y1)
			r11, g11, b11, a11 := rgbaAt(src, bounds.Min.X+x1, bounds.Min.Y+y1)

			dst.SetRGBA(dx, dy, color.RGBA{
				R: blend(r00, r10, r01, r11, weightX, weightY),
				G: blend(g00, g10, g01, g11, weightX, weightY),
				B: blend(b00, b10, b01, b11, weightX, weightY),
				A: blend(a00, a10, a01, a11, weightX, weightY),
			})
		}
	}
	return dst
}

func rgbaAt(src image.Image, x, y int) (uint8, uint8, uint8, uint8) {
	r, g, b, a := src.At(x, y).RGBA()
	return uint8(r >> 8), uint8(g >> 8), uint8(b >> 8), uint8(a >> 8)
}

func blend(v00, v10, v01, v11 uint8, weightX, weightY float64) uint8 {
	top := float64(v00)*(1-weightX) + float64(v10)*weightX
	bottom := float64(v01)*(1-weightX) + float64(v11)*weightX
	value := top*(1-weightY) + bottom*weightY
	if value < 0 {
		return 0
	}
	if value > 255 {
		return 255
	}
	return uint8(value)
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
