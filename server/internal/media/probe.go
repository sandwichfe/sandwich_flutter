package media

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"embyx/internal/dto"
)

// Prober 通过 ffprobe 子进程读取媒体技术信息，供扫描器和 PlaybackInfo 使用。
type Prober struct {
	ffprobePath string
}

func NewProber(ffprobePath string) *Prober {
	return &Prober{ffprobePath: ffprobePath}
}

type MediaInfo struct {
	DurationTicks int64
	Container     string
	Size          int64
	Bitrate       int
	Width         int
	Height        int
	Streams       []dto.MediaStreamInfo
}

type probeOutput struct {
	Format  probeFormat   `json:"format"`
	Streams []probeStream `json:"streams"`
}

type probeFormat struct {
	Filename   string `json:"filename"`
	FormatName string `json:"format_name"`
	Duration   string `json:"duration"`
	Size       string `json:"size"`
	BitRate    string `json:"bit_rate"`
}

type probeStream struct {
	Index              int               `json:"index"`
	CodecName          string            `json:"codec_name"`
	CodecTagString     string            `json:"codec_tag_string"`
	CodecType          string            `json:"codec_type"`
	Profile            string            `json:"profile"`
	Level              int               `json:"level"`
	Width              int               `json:"width"`
	Height             int               `json:"height"`
	DisplayAspectRatio string            `json:"display_aspect_ratio"`
	PixFmt             string            `json:"pix_fmt"`
	Refs               int               `json:"refs"`
	ColorPrimaries     string            `json:"color_primaries"`
	ColorSpace         string            `json:"color_space"`
	ColorTransfer      string            `json:"color_transfer"`
	FieldOrder         string            `json:"field_order"`
	RFrameRate         string            `json:"r_frame_rate"`
	AvgFrameRate       string            `json:"avg_frame_rate"`
	BitRate            string            `json:"bit_rate"`
	BitsPerRawSample   string            `json:"bits_per_raw_sample"`
	Channels           int               `json:"channels"`
	ChannelLayout      string            `json:"channel_layout"`
	SampleRate         string            `json:"sample_rate"`
	Disposition        probeDisposition  `json:"disposition"`
	Tags               map[string]string `json:"tags"`
}

type probeDisposition struct {
	Default int `json:"default"`
	Forced  int `json:"forced"`
}

func (p *Prober) Probe(ctx context.Context, filePath string) (*MediaInfo, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, p.ffprobePath,
		"-v", "quiet",
		"-print_format", "json",
		"-show_format",
		"-show_streams",
		filePath,
	)
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ffprobe 执行失败: %w", err)
	}

	return parseProbeOutput(output)
}

// parseProbeOutput 把 ffprobe 的 JSON 输出映射成 MediaInfo。
// 与执行子进程分离，测试可以直接喂 testdata 里的样本，不依赖机器上装了 ffprobe。
func parseProbeOutput(output []byte) (*MediaInfo, error) {
	var parsed probeOutput
	if err := json.Unmarshal(output, &parsed); err != nil {
		return nil, fmt.Errorf("解析 ffprobe 输出失败: %w", err)
	}

	info := &MediaInfo{
		Container:     parsed.Format.FormatName,
		DurationTicks: int64(parseFloat(parsed.Format.Duration) * 1e7),
		Size:          int64(parseFloat(parsed.Format.Size)),
		Bitrate:       parseInt(parsed.Format.BitRate),
	}

	for _, stream := range parsed.Streams {
		converted := convertStream(stream)
		info.Streams = append(info.Streams, converted)
		if stream.CodecType == "video" && info.Width == 0 {
			info.Width = stream.Width
			info.Height = stream.Height
		}
	}
	return info, nil
}

func convertStream(stream probeStream) dto.MediaStreamInfo {
	result := dto.MediaStreamInfo{
		Type:                 titleCase(stream.CodecType),
		Index:                stream.Index,
		Codec:                stream.CodecName,
		CodecTag:             stream.CodecTagString,
		Language:             stream.Tags["language"],
		Title:                stream.Tags["title"],
		Profile:              stream.Profile,
		AspectRatio:          stream.DisplayAspectRatio,
		PixelFormat:          stream.PixFmt,
		ColorPrimaries:       stream.ColorPrimaries,
		ColorSpace:           stream.ColorSpace,
		ColorTransfer:        stream.ColorTransfer,
		ChannelLayout:        stream.ChannelLayout,
		IsDefault:            stream.Disposition.Default == 1,
		IsExternal:           false,
		IsTextSubtitleStream: stream.CodecType == "subtitle" && stream.CodecName != "hdmv_pgs_subtitle",
	}

	if stream.Level > 0 {
		level := stream.Level
		result.Level = &level
	}
	if stream.Width > 0 {
		width := stream.Width
		result.Width = &width
	}
	if stream.Height > 0 {
		height := stream.Height
		result.Height = &height
	}
	if stream.Refs > 0 {
		refs := stream.Refs
		result.RefFrames = &refs
	}
	if bitrate := parseInt(stream.BitRate); bitrate > 0 {
		result.BitRate = &bitrate
	}
	if depth := parseInt(stream.BitsPerRawSample); depth > 0 {
		result.BitDepth = &depth
	}
	if stream.Channels > 0 {
		channels := stream.Channels
		result.Channels = &channels
	}
	if rate := parseInt(stream.SampleRate); rate > 0 {
		result.SampleRate = &rate
	}
	if fps := parseFrameRate(stream.AvgFrameRate); fps > 0 {
		result.AverageFrameRate = &fps
	}
	if fps := parseFrameRate(stream.RFrameRate); fps > 0 {
		result.RealFrameRate = &fps
	}
	if stream.FieldOrder == "tt" || stream.FieldOrder == "bb" {
		interlaced := true
		result.IsInterlaced = &interlaced
	}

	result.DisplayTitle = buildDisplayTitle(stream, result)
	return result
}

func buildDisplayTitle(stream probeStream, converted dto.MediaStreamInfo) string {
	switch stream.CodecType {
	case "video":
		resolution := ""
		if stream.Height > 0 {
			resolution = fmt.Sprintf("%dp", stream.Height)
		}
		parts := []string{resolution, strings.ToUpper(stream.CodecName)}
		if stream.ColorTransfer == "smpte2084" || stream.ColorTransfer == "arib-std-b67" {
			parts = append(parts, "HDR")
		} else {
			parts = append(parts, "SDR")
		}
		return strings.TrimSpace(strings.Join(parts, " "))
	case "audio":
		language := stream.Tags["language"]
		layout := stream.ChannelLayout
		return strings.TrimSpace(strings.Join([]string{language, strings.ToUpper(stream.CodecName), layout}, " "))
	case "subtitle":
		language := stream.Tags["language"]
		if title := stream.Tags["title"]; title != "" {
			return language + " " + title
		}
		return strings.TrimSpace(language + " " + strings.ToUpper(stream.CodecName))
	}
	return converted.Title
}

func titleCase(value string) string {
	if value == "" {
		return ""
	}
	return strings.ToUpper(value[:1]) + value[1:]
}

func parseFloat(value string) float64 {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil {
		return 0
	}
	return parsed
}

func parseInt(value string) int {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return 0
	}
	return parsed
}

func parseFrameRate(value string) float64 {
	if value == "" || value == "0/0" {
		return 0
	}
	parts := strings.SplitN(value, "/", 2)
	if len(parts) != 2 {
		return parseFloat(value)
	}
	numerator := parseFloat(parts[0])
	denominator := parseFloat(parts[1])
	if denominator == 0 {
		return 0
	}
	return math.Round(numerator/denominator*1000) / 1000
}
