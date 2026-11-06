// Package dto 定义与 Emby REST 协议完全对齐的响应结构。
// 字段名大小写不可随意改动：Flutter 客户端按原样读取这些 key。
package dto

import "encoding/json"

// ---------- 认证 ----------

type AuthenticationRequest struct {
	Username string `json:"Username"`
	Pw       string `json:"Pw"`
}

type AuthenticationResult struct {
	User        *UserDto     `json:"User"`
	AccessToken string       `json:"AccessToken"`
	ServerID    string       `json:"ServerId,omitempty"`
	SessionInfo *SessionInfo `json:"SessionInfo,omitempty"`
}

type UserDto struct {
	ID              string      `json:"Id"`
	Name            string      `json:"Name"`
	ServerID        string      `json:"ServerId,omitempty"`
	HasPassword     bool        `json:"HasPassword"`
	PrimaryImageTag string      `json:"PrimaryImageTag,omitempty"`
	IsDisabled      bool        `json:"IsDisabled,omitempty"`
	Policy          *UserPolicy `json:"Policy,omitempty"`
	LastLoginDate   string      `json:"LastLoginDate,omitempty"`
}

type UserPolicy struct {
	IsAdministrator bool `json:"IsAdministrator"`
	IsDisabled      bool `json:"IsDisabled"`
}

type SessionInfo struct {
	ID                 string `json:"Id,omitempty"`
	UserID             string `json:"UserId,omitempty"`
	UserName           string `json:"UserName,omitempty"`
	DeviceName         string `json:"DeviceName,omitempty"`
	Client             string `json:"Client,omitempty"`
	ApplicationVersion string `json:"ApplicationVersion,omitempty"`
}

// ---------- 通用条目 ----------

type BaseItemDto struct {
	ID   string `json:"Id,omitempty"`
	Name string `json:"Name,omitempty"`

	SortName string `json:"SortName,omitempty"`
	Type     string `json:"Type,omitempty"`

	Overview          string   `json:"Overview,omitempty"`
	Role              string   `json:"Role,omitempty"`
	ProductionYear    *int     `json:"ProductionYear,omitempty"`
	CommunityRating   *float64 `json:"CommunityRating,omitempty"`
	RunTimeTicks      *int64   `json:"RunTimeTicks,omitempty"`
	OfficialRating    string   `json:"OfficialRating,omitempty"`
	ChildCount        *int     `json:"ChildCount,omitempty"`
	Width             *int     `json:"Width,omitempty"`
	Height            *int     `json:"Height,omitempty"`
	Path              string   `json:"Path,omitempty"`
	PremiereDate      string   `json:"PremiereDate,omitempty"`
	DateCreated       string   `json:"DateCreated,omitempty"`
	IndexNumber       *int     `json:"IndexNumber,omitempty"`
	ParentIndexNumber *int     `json:"ParentIndexNumber,omitempty"`

	// 分片影片（本项目扩展）：一部影片被切成多个文件时，PartIndex/PartCount 用于画 `1/2` 徽标。
	// 只有 /Items/{itemId} 与 /Items/{itemId}/Siblings 会输出，普通影片没有这两个字段。
	PartIndex *int `json:"PartIndex,omitempty"`
	PartCount *int `json:"PartCount,omitempty"`
	// IsCurrent 只在兄弟列表里标记当前条目，前端据此高亮并禁用点击。
	IsCurrent bool `json:"IsCurrent,omitempty"`

	Genres  []string     `json:"Genres,omitempty"`
	Tags    []string     `json:"Tags,omitempty"`
	Studios []NameIDPair `json:"Studios,omitempty"`
	People  []PersonDto  `json:"People,omitempty"`

	// 演员(人物)详情字段：条目不会用到，只在 /Items/{personId} 里输出。
	// BirthDate 是出生年月日，PremiereDate 是首映/出道日期，两者互不影响。
	BirthDate string `json:"BirthDate,omitempty"`
	Gender    string `json:"Gender,omitempty"`
	CupSize   string `json:"CupSize,omitempty"`

	MediaSources []MediaSourceInfo `json:"MediaSources,omitempty"`
	Chapters     []ChapterInfo     `json:"Chapters,omitempty"`

	ProviderIDs  map[string]string `json:"ProviderIds,omitempty"`
	ExternalURLs []ExternalURL     `json:"ExternalUrls,omitempty"`

	ImageTags           map[string]string `json:"ImageTags,omitempty"`
	PrimaryImageTag     string            `json:"PrimaryImageTag,omitempty"`
	BackdropImageTags   []string          `json:"BackdropImageTags,omitempty"`
	ScreenshotImageTags []string          `json:"ScreenshotImageTags,omitempty"`

	UserData *UserItemDataDto `json:"UserData,omitempty"`

	// 媒体库(Views)专用字段
	CollectionType string   `json:"CollectionType,omitempty"`
	Locations      []string `json:"Locations,omitempty"`
	IsFolder       bool     `json:"IsFolder,omitempty"`
}

type NameIDPair struct {
	ID   string `json:"Id"`
	Name string `json:"Name"`
}

type PersonDto struct {
	ID              string            `json:"Id"`
	Name            string            `json:"Name"`
	Role            string            `json:"Role,omitempty"`
	Type            string            `json:"Type,omitempty"`
	PrimaryImageTag string            `json:"PrimaryImageTag,omitempty"`
	ImageTags       map[string]string `json:"ImageTags,omitempty"`

	// 写真 tag 来自本地 .actors 目录，扫描时随关联一起写入演员主表。
	BackdropImageTags []string `json:"BackdropImageTags,omitempty"`
}

type ExternalURL struct {
	Name string `json:"Name"`
	URL  string `json:"Url"`
}

type ChapterInfo struct {
	Name               string `json:"Name"`
	StartPositionTicks int64  `json:"StartPositionTicks"`
	ChapterIndex       int    `json:"ChapterIndex"`
	ImageTag           string `json:"ImageTag,omitempty"`
}

type UserItemDataDto struct {
	PlaybackPositionTicks int64   `json:"PlaybackPositionTicks"`
	PlayCount             int     `json:"PlayCount"`
	IsFavorite            bool    `json:"IsFavorite"`
	Played                bool    `json:"Played"`
	LastPlayedDate        string  `json:"LastPlayedDate,omitempty"`
	PlayedPercentage      float64 `json:"PlayedPercentage,omitempty"`
}

// ---------- 播放 ----------

type MediaSourceInfo struct {
	ID     string `json:"Id"`
	Name   string `json:"Name,omitempty"`
	Type   string `json:"Type,omitempty"` // Default / Grouping
	ItemID string `json:"ItemId,omitempty"`

	Path      string `json:"Path,omitempty"`
	Container string `json:"Container,omitempty"`

	Size         int64 `json:"Size,omitempty"`
	Bitrate      int   `json:"Bitrate,omitempty"`
	RunTimeTicks int64 `json:"RunTimeTicks,omitempty"`

	Protocol             string `json:"Protocol,omitempty"`
	IsRemote             bool   `json:"IsRemote"`
	SupportsDirectPlay   bool   `json:"SupportsDirectPlay"`
	SupportsDirectStream bool   `json:"SupportsDirectStream"`
	SupportsTranscoding  bool   `json:"SupportsTranscoding"`

	MediaStreams []MediaStreamInfo `json:"MediaStreams,omitempty"`
}

type MediaStreamInfo struct {
	Type         string `json:"Type"`
	Index        int    `json:"Index"`
	Codec        string `json:"Codec,omitempty"`
	CodecTag     string `json:"CodecTag,omitempty"`
	Language     string `json:"Language,omitempty"`
	Title        string `json:"Title,omitempty"`
	DisplayTitle string `json:"DisplayTitle,omitempty"`

	Profile string `json:"Profile,omitempty"`
	Level   *int   `json:"Level,omitempty"`

	Width            *int     `json:"Width,omitempty"`
	Height           *int     `json:"Height,omitempty"`
	AspectRatio      string   `json:"AspectRatio,omitempty"`
	IsInterlaced     *bool    `json:"IsInterlaced,omitempty"`
	AverageFrameRate *float64 `json:"AverageFrameRate,omitempty"`
	RealFrameRate    *float64 `json:"RealFrameRate,omitempty"`
	BitRate          *int     `json:"BitRate,omitempty"`
	BitDepth         *int     `json:"BitDepth,omitempty"`
	PixelFormat      string   `json:"PixelFormat,omitempty"`
	RefFrames        *int     `json:"RefFrames,omitempty"`
	ColorPrimaries   string   `json:"ColorPrimaries,omitempty"`
	ColorSpace       string   `json:"ColorSpace,omitempty"`
	ColorTransfer    string   `json:"ColorTransfer,omitempty"`

	ChannelLayout string `json:"ChannelLayout,omitempty"`
	Channels      *int   `json:"Channels,omitempty"`
	SampleRate    *int   `json:"SampleRate,omitempty"`

	IsDefault            bool `json:"IsDefault"`
	IsExternal           bool `json:"IsExternal,omitempty"`
	IsTextSubtitleStream bool `json:"IsTextSubtitleStream,omitempty"`
}

type PlaybackInfoRequest struct {
	ID                 string `json:"Id"`
	UserID             string `json:"UserId"`
	MediaSourceID      string `json:"MediaSourceId"`
	EnableDirectPlay   bool   `json:"EnableDirectPlay"`
	EnableDirectStream bool   `json:"EnableDirectStream"`
	EnableTranscoding  bool   `json:"EnableTranscoding"`
	IsPlayback         bool   `json:"IsPlayback"`
}

type PlaybackInfoResponse struct {
	MediaSources  []MediaSourceInfo `json:"MediaSources"`
	PlaySessionID string            `json:"PlaySessionId,omitempty"`
	ErrorCode     string            `json:"ErrorCode,omitempty"`
}

type PlaybackProgressInfo struct {
	ItemID        string  `json:"ItemId"`
	UserID        string  `json:"UserId"`
	MediaSourceID string  `json:"MediaSourceId,omitempty"`
	PlaySessionID string  `json:"PlaySessionId,omitempty"`
	PositionTicks int64   `json:"PositionTicks"`
	IsPaused      bool    `json:"IsPaused"`
	IsMuted       bool    `json:"IsMuted"`
	VolumeLevel   int     `json:"VolumeLevel"`
	CanSeek       bool    `json:"CanSeek"`
	PlayMethod    string  `json:"PlayMethod,omitempty"`
	PlaybackRate  float64 `json:"PlaybackRate,omitempty"`
	EventName     string  `json:"EventName,omitempty"`
	Failed        bool    `json:"Failed,omitempty"`
}

// ---------- 列表 ----------

type QueryResult struct {
	Items            []BaseItemDto `json:"Items"`
	TotalRecordCount int           `json:"TotalRecordCount"`
	StartIndex       int           `json:"StartIndex,omitempty"`
}

type ImageInfo struct {
	ImageType  string `json:"ImageType"`
	ImageIndex int    `json:"ImageIndex"`
	Filename   string `json:"Filename,omitempty"`
	Width      int    `json:"Width,omitempty"`
	Height     int    `json:"Height,omitempty"`
	Size       int64  `json:"Size,omitempty"`
}

// MarshalRaw 便于在 handler 里复用手动拼装的 JSON 片段。
func MarshalRaw(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	if err != nil {
		return json.RawMessage("null")
	}
	return raw
}
