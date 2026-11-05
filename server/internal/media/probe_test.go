package media

import (
	"os"
	"path/filepath"
	"testing"
)

// loadProbeSample 读 testdata 下真实的 ffprobe 输出样本，测试不需要装 ffprobe。
func loadProbeSample(t *testing.T, name string) *MediaInfo {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("读取样本 %s 失败: %v", name, err)
	}
	info, err := parseProbeOutput(raw)
	if err != nil {
		t.Fatalf("解析样本 %s 失败: %v", name, err)
	}
	return info
}

func derefInt(value *int) int {
	if value == nil {
		return -1
	}
	return *value
}

func TestParseProbeOutputFormatAndFirstVideo(t *testing.T) {
	info := loadProbeSample(t, "probe_4k_hdr.json")

	if info.Container != "mov,mp4,m4a,3gp,3g2,mj2" {
		t.Errorf("容器 = %q", info.Container)
	}
	if info.DurationTicks != 72005000000 {
		t.Errorf("时长 ticks = %d，期望 72005000000", info.DurationTicks)
	}
	if info.Size != 9000000000 || info.Bitrate != 10000000 {
		t.Errorf("体积/码率 = %d/%d", info.Size, info.Bitrate)
	}
	// 宽高取首个视频流，不与音频/字幕流混淆。
	if info.Width != 3840 || info.Height != 2160 {
		t.Errorf("宽高 = %dx%d", info.Width, info.Height)
	}
	if len(info.Streams) != 4 {
		t.Fatalf("流数量 = %d，期望 4", len(info.Streams))
	}

	video := info.Streams[0]
	if video.Type != "Video" || video.Codec != "hevc" || video.CodecTag != "hvc1" {
		t.Errorf("视频流基本字段错误: %+v", video)
	}
	if video.DisplayTitle != "2160p HEVC HDR" {
		t.Errorf("视频 DisplayTitle = %q", video.DisplayTitle)
	}
	if video.ColorTransfer != "smpte2084" || video.ColorPrimaries != "bt2020" {
		t.Errorf("HDR 色彩信息丢失: %+v", video)
	}
	if got := derefInt(video.BitDepth); got != 10 {
		t.Errorf("位深 = %d，期望 10", got)
	}
	if got := derefInt(video.Level); got != 153 {
		t.Errorf("Level = %d，期望 153", got)
	}
	if got := derefInt(video.RefFrames); got != 4 {
		t.Errorf("参考帧 = %d，期望 4", got)
	}
	if got := derefInt(video.Width); got != 3840 {
		t.Errorf("流宽度 = %d，期望 3840", got)
	}
	if video.AverageFrameRate == nil || *video.AverageFrameRate != 23.976 {
		t.Errorf("平均帧率 = %v，期望 23.976", video.AverageFrameRate)
	}
	if video.IsDefault != true || video.Language != "jpn" {
		t.Errorf("默认轨/语言标记错误: %+v", video)
	}
}

func TestParseProbeOutputAudioAndSubtitles(t *testing.T) {
	info := loadProbeSample(t, "probe_4k_hdr.json")

	audio := info.Streams[1]
	if audio.Type != "Audio" || audio.Codec != "eac3" {
		t.Errorf("音频流基本字段错误: %+v", audio)
	}
	if audio.DisplayTitle != "jpn EAC3 5.1(side)" {
		t.Errorf("音频 DisplayTitle = %q", audio.DisplayTitle)
	}
	if got := derefInt(audio.Channels); got != 6 {
		t.Errorf("声道数 = %d，期望 6", got)
	}
	if got := derefInt(audio.SampleRate); got != 48000 {
		t.Errorf("采样率 = %d，期望 48000", got)
	}
	if audio.Width != nil || audio.Height != nil {
		t.Errorf("音频流不应带宽高: %+v", audio)
	}

	// 文本字幕可以直接在客户端渲染，图形字幕（PGS）不行，客户端据此决定是否外挂。
	textSub := info.Streams[2]
	if !textSub.IsTextSubtitleStream {
		t.Errorf("subrip 应视为文本字幕: %+v", textSub)
	}
	if textSub.DisplayTitle != "chi 简体中文" {
		t.Errorf("字幕 DisplayTitle = %q", textSub.DisplayTitle)
	}
	if info.Streams[3].IsTextSubtitleStream {
		t.Errorf("hdmv_pgs_subtitle 不应视为文本字幕")
	}
}

func TestParseProbeOutputLegacyInterlaced(t *testing.T) {
	info := loadProbeSample(t, "probe_interlaced_dvd.json")

	// ffprobe 对不支持的字段会输出 "N/A"/空串，解析必须退化成 0 而不是报错。
	if info.DurationTicks != 0 || info.Size != 0 || info.Bitrate != 0 {
		t.Errorf("缺失字段应解析为 0: %+v", info)
	}
	video := info.Streams[0]
	if video.DisplayTitle != "576p MPEG2VIDEO SDR" {
		t.Errorf("DisplayTitle = %q", video.DisplayTitle)
	}
	if video.IsInterlaced == nil || !*video.IsInterlaced {
		t.Errorf("tt 场序应判定为隔行")
	}
	// 0/0 表示未知帧率，不能输出一个无效数值。
	if video.AverageFrameRate != nil || video.RealFrameRate != nil {
		t.Errorf("未知帧率应为空: avg=%v real=%v", video.AverageFrameRate, video.RealFrameRate)
	}
}

func TestParseProbeOutputRejectsBrokenJSON(t *testing.T) {
	if _, err := parseProbeOutput([]byte("not json")); err == nil {
		t.Fatal("非法 JSON 应返回错误")
	}
}
