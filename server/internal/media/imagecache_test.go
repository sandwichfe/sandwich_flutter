package media

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestImageRendererCachesScaledOutput(t *testing.T) {
	dir := t.TempDir()
	renderer := NewImageRenderer(dir)
	raw := makePNG(t, 400, 200, false)

	first, tag, err := renderer.Render("item1", "Primary", 0, raw, 100, 82)
	if err != nil {
		t.Fatalf("首次渲染失败: %v", err)
	}
	if width, _, err := DecodeConfig(first); err != nil || width != 100 {
		t.Fatalf("渲染结果宽度 = %d (err=%v), 期望 100", width, err)
	}

	second, secondTag, err := renderer.Render("item1", "Primary", 0, raw, 100, 82)
	if err != nil {
		t.Fatalf("二次渲染失败: %v", err)
	}
	if !bytes.Equal(first, second) || tag != secondTag {
		t.Error("同一张图同一参数应返回完全一致的结果")
	}

	// 命中缓存时不应产生第二份文件。
	entries, err := os.ReadDir(filepath.Join(dir, "item1"))
	if err != nil {
		t.Fatalf("读取缓存目录失败: %v", err)
	}
	if len(entries) != 1 {
		t.Errorf("缓存文件数 = %d, 期望 1", len(entries))
	}

	// 源图换了内容，标签必须变化，否则客户端会拿到旧图。
	changed := makePNG(t, 400, 200, true)
	if _, changedTag, err := renderer.Render("item1", "Primary", 0, changed, 100, 82); err != nil {
		t.Fatalf("渲染替换后的图失败: %v", err)
	} else if changedTag == tag {
		t.Error("源图内容变化后标签应发生变化")
	}
}

func TestNormalizeRenderParams(t *testing.T) {
	if got := NormalizeRenderWidth(99999); got != maxRenderWidth {
		t.Errorf("超宽应钳到 %d, 实际 %d", maxRenderWidth, got)
	}
	if got := NormalizeRenderWidth(-1); got != 0 {
		t.Errorf("负宽度应归零, 实际 %d", got)
	}
	if got := NormalizeRenderQuality(0); got != defaultImageQuality {
		t.Errorf("画质 0 应回落默认值, 实际 %d", got)
	}
	if got := NormalizeRenderQuality(101); got != defaultImageQuality {
		t.Errorf("画质 101 应回落默认值, 实际 %d", got)
	}
	if got := NormalizeRenderQuality(50); got != 50 {
		t.Errorf("合法画质不应被改写, 实际 %d", got)
	}
}

// TestResizeBilinearAverages 校验缩放后的像素值：
// 4 个纯色块缩到 1×1 时，双线性插值的结果应接近四角颜色的平均值。
func TestResizeBilinearAverages(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 2, 2))
	src.SetRGBA(0, 0, color.RGBA{R: 0, G: 0, B: 0, A: 255})
	src.SetRGBA(1, 0, color.RGBA{R: 100, G: 100, B: 100, A: 255})
	src.SetRGBA(0, 1, color.RGBA{R: 200, G: 200, B: 200, A: 255})
	src.SetRGBA(1, 1, color.RGBA{R: 255, G: 255, B: 255, A: 255})

	dst := resizeBilinear(src, 1, 1)
	got := dst.RGBAAt(0, 0)
	// 期望值 ≈ (0+100+200+255)/4 = 138.75
	if got.R < 135 || got.R > 142 {
		t.Errorf("缩放结果 R = %d, 期望约 139", got.R)
	}
	if got.A != 255 {
		t.Errorf("缩放结果 A = %d, 期望 255", got.A)
	}
}

// makePNG 生成一张测试用的 PNG；gradient 为 true 时每行颜色不同，用于制造内容差异。
func makePNG(t *testing.T, width, height int, gradient bool) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			shade := uint8(x * 255 / width)
			if gradient {
				shade = uint8(y * 255 / height)
			}
			img.SetRGBA(x, y, color.RGBA{R: shade, G: 128, B: 64, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("生成测试图片失败: %v", err)
	}
	return buf.Bytes()
}
