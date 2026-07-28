// Emby 桌面端模型保留服务端字段含义，避免页面层重复解析 JSON。
class EmbyPcItem {
  final String id;
  final String name;

  // 排序名用于人物页摘要，缺失时由页面自动隐藏。
  final String sortName;
  final String type;
  final String overview;
  final String? role;
  final int? productionYear;
  final double? communityRating;
  final int runTimeTicks;
  final String officialRating;
  final int? childCount;
  final int? width;
  final int? height;
  final String path;
  final String premiereDate;
  final String dateCreated;
  final bool isFavorite;
  final bool played;
  final int playbackPositionTicks;
  final List<String> genres;
  final List<String> tags;
  final List<EmbyPcNamedItem> studios;
  final List<EmbyPcPerson> people;
  final List<EmbyPcMediaSource> mediaSources;
  final List<EmbyPcChapter> chapters;

  // 外部编号和链接来自人物详情接口，也保留在通用条目模型中统一解析。
  final Map<String, String> providerIds;
  final List<EmbyPcExternalUrl> externalUrls;
  final Map<String, dynamic> imageTags;
  final String primaryImageTag;
  final List<String> backdropImageTags;
  final List<String> screenshotImageTags;

  const EmbyPcItem({
    required this.id,
    required this.name,
    this.sortName = '',
    this.type = '',
    this.overview = '',
    this.role,
    this.productionYear,
    this.communityRating,
    this.runTimeTicks = 0,
    this.officialRating = '',
    this.childCount,
    this.width,
    this.height,
    this.path = '',
    this.premiereDate = '',
    this.dateCreated = '',
    this.isFavorite = false,
    this.played = false,
    this.playbackPositionTicks = 0,
    this.genres = const [],
    this.tags = const [],
    this.studios = const [],
    this.people = const [],
    this.mediaSources = const [],
    this.chapters = const [],
    this.providerIds = const {},
    this.externalUrls = const [],
    this.imageTags = const {},
    this.primaryImageTag = '',
    this.backdropImageTags = const [],
    this.screenshotImageTags = const [],
  });

  factory EmbyPcItem.fromJson(Map<String, dynamic> json) {
    final userData = _map(json['UserData']);
    return EmbyPcItem(
      id: _text(json['Id']),
      name: _text(json['Name']),
      sortName: _text(json['SortName']),
      type: _text(json['Type']),
      overview: _text(json['Overview']),
      role: json['Role']?.toString(),
      productionYear: _integerOrNull(json['ProductionYear']),
      communityRating: _doubleOrNull(json['CommunityRating']),
      runTimeTicks: _integer(json['RunTimeTicks']),
      officialRating: _text(json['OfficialRating']),
      childCount: _integerOrNull(json['ChildCount']),
      width: _integerOrNull(json['Width']),
      height: _integerOrNull(json['Height']),
      path: _text(json['Path']),
      premiereDate: _text(json['PremiereDate']),
      dateCreated: _text(json['DateCreated']),
      isFavorite: userData['IsFavorite'] == true,
      played: userData['Played'] == true,
      playbackPositionTicks: _integer(userData['PlaybackPositionTicks']),
      genres: _strings(json['Genres']),
      tags: _strings(json['Tags']),
      studios: _maps(json['Studios']).map(EmbyPcNamedItem.fromJson).toList(),
      people: _maps(json['People']).map(EmbyPcPerson.fromJson).toList(),
      mediaSources:
          _maps(json['MediaSources']).map(EmbyPcMediaSource.fromJson).toList(),
      chapters: _maps(json['Chapters']).map(EmbyPcChapter.fromJson).toList(),
      providerIds: _stringMap(json['ProviderIds']),
      externalUrls:
          _maps(json['ExternalUrls']).map(EmbyPcExternalUrl.fromJson).toList(),
      imageTags: _map(json['ImageTags']),
      primaryImageTag: _text(json['PrimaryImageTag']),
      backdropImageTags: _strings(json['BackdropImageTags']),
      screenshotImageTags: _strings(json['ScreenshotImageTags']),
    );
  }

  EmbyPcItem copyWith({bool? isFavorite}) => EmbyPcItem(
    id: id,
    name: name,
    sortName: sortName,
    type: type,
    overview: overview,
    role: role,
    productionYear: productionYear,
    communityRating: communityRating,
    runTimeTicks: runTimeTicks,
    officialRating: officialRating,
    childCount: childCount,
    width: width,
    height: height,
    path: path,
    premiereDate: premiereDate,
    dateCreated: dateCreated,
    isFavorite: isFavorite ?? this.isFavorite,
    played: played,
    playbackPositionTicks: playbackPositionTicks,
    genres: genres,
    tags: tags,
    studios: studios,
    people: people,
    mediaSources: mediaSources,
    chapters: chapters,
    providerIds: providerIds,
    externalUrls: externalUrls,
    imageTags: imageTags,
    primaryImageTag: primaryImageTag,
    backdropImageTags: backdropImageTags,
    screenshotImageTags: screenshotImageTags,
  );

  bool get hasPrimaryImage =>
      primaryImageTag.isNotEmpty || imageTags['Primary'] != null;

  bool get hasBackdropImage => backdropImageTags.isNotEmpty;

  Duration get duration => Duration(microseconds: runTimeTicks ~/ 10);

  String get runtimeLabel {
    if (runTimeTicks <= 0) return '';
    final minutes = duration.inMinutes;
    final hours = minutes ~/ 60;
    return hours > 0 ? '${hours}h ${minutes % 60}m' : '${minutes}m';
  }
}

// Emby 外部链接保留名称和地址，页面可在名称缺失时使用 URL 兜底显示。
class EmbyPcExternalUrl {
  final String name;
  final String url;

  const EmbyPcExternalUrl({this.name = '', this.url = ''});

  factory EmbyPcExternalUrl.fromJson(Map<String, dynamic> json) =>
      EmbyPcExternalUrl(name: _text(json['Name']), url: _text(json['Url']));
}

class EmbyPcPerson {
  final String id;
  final String name;
  final String role;
  final String type;

  // 人物图片标签用于在演职人员卡片中判断是否请求头像。
  final String primaryImageTag;
  final Map<String, dynamic> imageTags;

  const EmbyPcPerson({
    required this.id,
    required this.name,
    this.role = '',
    this.type = '',
    this.primaryImageTag = '',
    this.imageTags = const {},
  });

  factory EmbyPcPerson.fromJson(Map<String, dynamic> json) => EmbyPcPerson(
    id: _text(json['Id']),
    name: _text(json['Name']),
    role: _text(json['Role']),
    type: _text(json['Type']),
    primaryImageTag: _text(json['PrimaryImageTag']),
    imageTags: _map(json['ImageTags']),
  );

  bool get hasPrimaryImage =>
      primaryImageTag.isNotEmpty || imageTags['Primary'] != null;
}

class EmbyPcNamedItem {
  final String id;
  final String name;

  const EmbyPcNamedItem({required this.id, required this.name});

  factory EmbyPcNamedItem.fromJson(Map<String, dynamic> json) =>
      EmbyPcNamedItem(id: _text(json['Id']), name: _text(json['Name']));
}

class EmbyPcChapter {
  final String name;
  final int startPositionTicks;
  final int index;
  final String imageTag;

  const EmbyPcChapter({
    required this.name,
    required this.startPositionTicks,
    required this.index,
    this.imageTag = '',
  });

  factory EmbyPcChapter.fromJson(Map<String, dynamic> json) => EmbyPcChapter(
    name: _text(json['Name']),
    startPositionTicks: _integer(json['StartPositionTicks']),
    index: _integer(json['ChapterIndex']),
    imageTag: _text(json['ImageTag']),
  );
}

class EmbyPcMediaSource {
  final String id;
  final String path;
  final String container;
  final int size;
  final int bitrate;
  final int runTimeTicks;
  final List<EmbyPcMediaStream> streams;

  const EmbyPcMediaSource({
    required this.id,
    this.path = '',
    this.container = '',
    this.size = 0,
    this.bitrate = 0,
    this.runTimeTicks = 0,
    this.streams = const [],
  });

  factory EmbyPcMediaSource.fromJson(Map<String, dynamic> json) =>
      EmbyPcMediaSource(
        id: _text(json['Id']),
        path: _text(json['Path']),
        container: _text(json['Container']),
        size: _integer(json['Size']),
        bitrate: _integer(json['Bitrate']),
        runTimeTicks: _integer(json['RunTimeTicks']),
        streams:
            _maps(
              json['MediaStreams'],
            ).map(EmbyPcMediaStream.fromJson).toList(),
      );
}

class EmbyPcMediaStream {
  final String type;
  final String title;
  final String codec;
  final String language;

  // 保留 Emby 返回的流详情字段，供视频与音频信息卡片逐项展示。
  final String codecTag;
  final String profile;
  final int? level;
  final int? width;
  final int? height;
  final String aspectRatio;
  final bool? isInterlaced;
  final double? averageFrameRate;
  final double? realFrameRate;
  final int? bitrate;
  final int? bitDepth;
  final String pixelFormat;
  final int? refFrames;
  final String colorPrimaries;
  final String colorSpace;
  final String colorTransfer;
  final String channelLayout;
  final int? channels;
  final int? sampleRate;
  final bool? isDefault;

  const EmbyPcMediaStream({
    required this.type,
    required this.title,
    required this.codec,
    required this.language,
    this.codecTag = '',
    this.profile = '',
    this.level,
    this.width,
    this.height,
    this.aspectRatio = '',
    this.isInterlaced,
    this.averageFrameRate,
    this.realFrameRate,
    this.bitrate,
    this.bitDepth,
    this.pixelFormat = '',
    this.refFrames,
    this.colorPrimaries = '',
    this.colorSpace = '',
    this.colorTransfer = '',
    this.channelLayout = '',
    this.channels,
    this.sampleRate,
    this.isDefault,
  });

  factory EmbyPcMediaStream.fromJson(Map<String, dynamic> json) =>
      EmbyPcMediaStream(
        type: _text(json['Type']),
        title:
            _text(json['DisplayTitle']).isNotEmpty
                ? _text(json['DisplayTitle'])
                : _text(json['Title']),
        codec: _text(json['Codec']),
        language: _text(json['Language']),
        codecTag: _text(json['CodecTag']),
        profile: _text(json['Profile']),
        level: _integerOrNull(json['Level']),
        width: _integerOrNull(json['Width']),
        height: _integerOrNull(json['Height']),
        aspectRatio: _text(json['AspectRatio']),
        isInterlaced: _booleanOrNull(json['IsInterlaced']),
        averageFrameRate: _doubleOrNull(json['AverageFrameRate']),
        realFrameRate: _doubleOrNull(json['RealFrameRate']),
        bitrate: _integerOrNull(json['BitRate']),
        bitDepth: _integerOrNull(json['BitDepth']),
        pixelFormat: _text(json['PixelFormat']),
        refFrames: _integerOrNull(json['RefFrames']),
        colorPrimaries: _text(json['ColorPrimaries']),
        colorSpace: _text(json['ColorSpace']),
        colorTransfer: _text(json['ColorTransfer']),
        channelLayout: _text(json['ChannelLayout']),
        channels: _integerOrNull(json['Channels']),
        sampleRate: _integerOrNull(json['SampleRate']),
        isDefault: _booleanOrNull(json['IsDefault']),
      );
}

class EmbyPcPage {
  final List<EmbyPcItem> items;
  final int total;

  const EmbyPcPage({required this.items, required this.total});

  factory EmbyPcPage.fromJson(Map<String, dynamic> json) {
    final items = _maps(json['Items']).map(EmbyPcItem.fromJson).toList();
    return EmbyPcPage(
      items: items,
      total: _integerOrNull(json['TotalRecordCount']) ?? items.length,
    );
  }
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

// ProviderIds 的值应为字符串，空值在模型层过滤，避免页面重复清洗。
Map<String, String> _stringMap(dynamic value) => {
  for (final entry in _map(value).entries)
    if (_text(entry.value).isNotEmpty) entry.key: _text(entry.value),
};

List<Map<String, dynamic>> _maps(dynamic value) =>
    value is List
        ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
        : <Map<String, dynamic>>[];

List<String> _strings(dynamic value) =>
    value is List ? value.map((item) => item.toString()).toList() : const [];

String _text(dynamic value) => value?.toString() ?? '';

int _integer(dynamic value) => _integerOrNull(value) ?? 0;

int? _integerOrNull(dynamic value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

double? _doubleOrNull(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');

bool? _booleanOrNull(dynamic value) {
  if (value is bool) return value;
  if (value?.toString().toLowerCase() == 'true') return true;
  if (value?.toString().toLowerCase() == 'false') return false;
  return null;
}
