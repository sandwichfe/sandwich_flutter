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

// 图片来源标记：一个槽位只有一张图，origin 说明它是怎么来的。
// 扫描导入时据此避免覆盖用户自己上传或生成的图。
const (
	OriginImport   = "import"
	OriginUpload   = "upload"
	OriginGenerate = "generate"
	OriginAuto     = "auto"
)

func (s *ImageStore) ItemPath(itemID, imageType string, index int) string {
	return filepath.Join(s.root, sanitizeID(itemID), sanitizeImageType(imageType), strconv.Itoa(index)+".jpg")
}

// sanitizeImageType 对图片类型做白名单清洗。
// 上传接口会把请求体直接写到这个路径，仅靠 http.ServeMux 清理 ".." 属于防御缺失。
func sanitizeImageType(value string) string {
	cleaned := strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' {
			return r
		}
		return -1
	}, strings.ToLower(value))
	if cleaned == "" {
		return "unknown"
	}
	return cleaned
}

// ItemMetaPath 返回图片旁边的派生信息文件路径（来源、重建签名、删除标记等）。
// 派生信息跟着图片文件走，删除图片时只清目录即可，不必为它新增数据库列。
func (s *ImageStore) ItemMetaPath(itemID, imageType string, index int, ext string) string {
	path := s.ItemPath(itemID, imageType, index)
	return strings.TrimSuffix(path, filepath.Ext(path)) + "." + ext
}

// WriteOrigin 记录这张图是怎么来的：扫描导入、手动上传、视频生成、自动拼接。
// 扫描导入时据此判断是否该覆盖现有图。
func (s *ImageStore) WriteOrigin(itemID, imageType string, index int, origin string) error {
	path := s.ItemMetaPath(itemID, imageType, index, "origin")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := writeFileAtomic(path, []byte(origin)); err != nil {
		return fmt.Errorf("写入图片来源失败: %w", err)
	}
	return nil
}

func (s *ImageStore) ReadOrigin(itemID, imageType string, index int) string {
	raw, err := os.ReadFile(s.ItemMetaPath(itemID, imageType, index, "origin"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

// RemoveOrigin 删除来源标记；图片被删掉后旧来源不能残留，
// 否则扫描会误以为这张图仍是用户上传的而跳过重新导入。
func (s *ImageStore) RemoveOrigin(itemID, imageType string, index int) error {
	err := os.Remove(s.ItemMetaPath(itemID, imageType, index, "origin"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// ItemLockedPath 是条目图片锁的标记文件。锁跟图片目录走，不需要新增数据库列，
// 和 .origin / .disabled 一样属于条目的派生状态。
func (s *ImageStore) ItemLockedPath(itemID string) string {
	return filepath.Join(s.root, sanitizeID(itemID), "locked")
}

// SetItemLocked 设置图片锁：锁定后扫描导入与自动重建封面都不会覆盖这个条目的图片。
// 手动上传、手动生成、手动删除仍然允许，锁只挡自动流程。
func (s *ImageStore) SetItemLocked(itemID string, locked bool) error {
	path := s.ItemLockedPath(itemID)
	if !locked {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := writeFileAtomic(path, []byte("1")); err != nil {
		return fmt.Errorf("写入图片锁失败: %w", err)
	}
	return nil
}

// ItemLocked 表示这个条目的图片被用户锁定了，自动流程不能覆盖。
func (s *ImageStore) ItemLocked(itemID string) bool {
	return fileExists(s.ItemLockedPath(itemID))
}

// HasItemImage 只判断文件是否存在且非空。
// 批量检查缺图时用它，避免为了确认存在就读整张图。
func (s *ImageStore) HasItemImage(itemID, imageType string, index int) bool {
	return fileExists(s.ItemPath(itemID, imageType, index))
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
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
