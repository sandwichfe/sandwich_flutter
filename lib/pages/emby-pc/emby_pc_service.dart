import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'emby_pc_models.dart';

// 三类播放上报使用不同接口和请求字段，避免服务端错误关联播放会话。
enum EmbyPcPlaybackEvent { started, progress, stopped }

// 桌面端使用独立会话，避免覆盖现有移动端 Emby 页面的登录状态。
class EmbyPcService {
  static final EmbyPcService instance = EmbyPcService._();

  EmbyPcService._();

  static const _serverKey = 'emby_pc_server';
  static const _userIdKey = 'emby_pc_user_id';
  static const _tokenKey = 'emby_pc_token';
  static const _userNameKey = 'emby_pc_user_name';
  static const _loginNameKey = 'emby_pc_login_name';
  static const _passwordKey = 'emby_pc_password';
  static const _rememberKey = 'emby_pc_remember_password';
  static const _sortByKey = 'emby_pc_sort_by';
  static const _sortOrderKey = 'emby_pc_sort_order';
  static const _imageStyleKey = 'emby_pc_image_style';
  static const _libraryOrderKey = 'emby_pc_library_order';

  String serverUrl = '';
  String userId = '';
  String accessToken = '';
  String currentUserName = '';
  int _userAvatarRevision = 0;

  bool get isLoggedIn => accessToken.isNotEmpty && userId.isNotEmpty;

  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString(_serverKey) ?? '';
    userId = prefs.getString(_userIdKey) ?? '';
    accessToken = prefs.getString(_tokenKey) ?? '';
    currentUserName = prefs.getString(_userNameKey) ?? '';
  }

  Future<EmbyPcSavedLogin> readSavedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    return EmbyPcSavedLogin(
      serverUrl: prefs.getString(_serverKey) ?? 'http://localhost:8096',
      username: prefs.getString(_loginNameKey) ?? '',
      password: prefs.getString(_passwordKey) ?? '',
      rememberPassword: prefs.getBool(_rememberKey) ?? false,
    );
  }

  Future<void> login({
    required String server,
    required String username,
    required String password,
    required bool rememberPassword,
  }) async {
    final normalized = normalizeServerUrl(server);
    final response = await http.post(
      Uri.parse('$normalized/emby/Users/AuthenticateByName'),
      headers: {
        'X-Emby-Authorization':
            'MediaBrowser Client="EmbyX Flutter", Device="Desktop", DeviceId="embyx-flutter-desktop", Version="1.0.0"',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'Username': username.trim(), 'Pw': password}),
    );
    // 登录接口的鉴权失败代表凭据或账号权限问题，不应提示已有会话失效。
    if (response.statusCode == 401) {
      throw const EmbyPcException('用户名或密码错误');
    }
    if (response.statusCode == 403) {
      throw const EmbyPcException('该账号不允许登录');
    }
    final data = _decodeResponse(response, 'Emby 登录失败');
    final user = _asMap(data['User']);
    final token = data['AccessToken']?.toString() ?? '';
    final id = user['Id']?.toString() ?? '';
    if (token.isEmpty || id.isEmpty) {
      throw const EmbyPcException('Emby 登录响应缺少用户或 Token 信息');
    }

    serverUrl = normalized;
    userId = id;
    accessToken = token;
    currentUserName = user['Name']?.toString() ?? username.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, serverUrl);
    await prefs.setString(_userIdKey, userId);
    await prefs.setString(_tokenKey, accessToken);
    await prefs.setString(_userNameKey, currentUserName);
    await prefs.setString(_loginNameKey, username.trim());
    await prefs.setBool(_rememberKey, rememberPassword);
    if (rememberPassword) {
      await prefs.setString(_passwordKey, password);
    } else {
      await prefs.remove(_passwordKey);
    }
  }

  Future<void> logout() async {
    accessToken = '';
    userId = '';
    currentUserName = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_userNameKey);
  }

  Future<List<EmbyPcItem>> getLibraries() async {
    final data = await _get('/emby/Users/$userId/Views');
    return EmbyPcPage.fromJson(data).items;
  }

  Future<String> scanLibrary() async {
    final response = await http.post(
      _uri('/emby/Library/Refresh'),
      headers: _tokenHeader,
    );
    return _responseText(response, '扫描媒体库失败');
  }

  Future<String> refreshMetadata(
    String itemId, {
    required String mode,
    required bool replaceImages,
    required bool replaceThumbnailImages,
  }) async {
    final replaceMetadata = mode == 'FullRefresh';
    final response = await http.post(
      _uri('/emby/Items/$itemId/Refresh', {
        'Recursive': 'true',
        'MetadataRefreshMode': mode,
        'ImageRefreshMode': replaceImages ? 'FullRefresh' : 'Default',
        'ReplaceAllMetadata': '$replaceMetadata',
        'ReplaceAllImages': '$replaceImages',
      }),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      // Swagger 将视频预览缩略图选项定义在 BaseRefreshRequest 正文中。
      body: jsonEncode({'ReplaceThumbnailImages': replaceThumbnailImages}),
    );
    return _responseText(response, '刷新元数据失败');
  }

  Future<List<EmbyPcImageInfo>> getItemImages(String itemId) async {
    final response = await http.get(
      _uri('/emby/Items/$itemId/Images'),
      headers: _tokenHeader,
    );
    _ensureSuccess(response, '获取图像失败');
    if (response.bodyBytes.isEmpty) return const [];
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! List) throw const EmbyPcException('获取图像失败：响应格式错误');
    return data
        .whereType<Map>()
        .map((item) => EmbyPcImageInfo.fromJson(_asMap(item)))
        .toList();
  }

  Future<void> uploadItemImage(
    String itemId, {
    required String type,
    int? index,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final path = index == null
        ? '/emby/Items/$itemId/Images/$type'
        : '/emby/Items/$itemId/Images/$type/$index';
    final response = await http.post(
      _uri(path),
      headers: {..._tokenHeader, 'Content-Type': contentType},
      // Emby 图像接口接收以 Base64 编码后的文件内容。
      body: base64Encode(bytes),
    );
    _ensureSuccess(response, '上传图像失败');
  }

  Future<void> uploadUserAvatar({
    required Uint8List bytes,
    required String contentType,
  }) async {
    final response = await http.post(
      _uri('/emby/Users/$userId/Images/Primary'),
      headers: {..._tokenHeader, 'Content-Type': contentType},
      // Swagger 要求用户图像正文使用 Base64 编码，和媒体图像上传规则一致。
      body: base64Encode(bytes),
    );
    _ensureSuccess(response, '上传头像失败');
    _userAvatarRevision++;
  }

  Future<void> deleteItemImage(
    String itemId, {
    required String type,
    required int index,
  }) async {
    final response = await http.delete(
      _uri('/emby/Items/$itemId/Images/$type/$index'),
      headers: _tokenHeader,
    );
    _ensureSuccess(response, '删除图像失败');
  }

  Future<EmbyPcPage> getItems({
    String libraryId = '',
    bool favoriteOnly = false,
    int startIndex = 0,
    int limit = 100,
    String itemType = '',
    String filters = '',
    String videoType = '',
    String searchTerm = '',
    int? productionYear,
    String sortBy = 'PremiereDate',
    String sortOrder = 'Descending',
  }) async {
    final types =
        const {'Movie', 'Series', 'Video', 'Person'}.contains(itemType)
        ? itemType
        : 'Movie,Series,Video';
    final query = <String, String>{
      'Recursive': 'true',
      'IncludeItemTypes': types,
      'Fields':
          'Overview,ProductionYear,PremiereDate,DateCreated,CommunityRating,RunTimeTicks,Width,Height',
      'EnableUserData': 'true',
      'EnableImageTypes': 'Primary,Backdrop',
      'SortBy': sortBy,
      'SortOrder': sortOrder,
      'StartIndex': '$startIndex',
      'Limit': '${limit.clamp(1, 100)}',
    };
    if (!favoriteOnly && libraryId.isNotEmpty) query['ParentId'] = libraryId;
    final mergedFilters = <String>{
      if (favoriteOnly) 'IsFavorite',
      ...filters.split(',').where((value) => value.isNotEmpty),
    };
    if (mergedFilters.isNotEmpty) query['Filters'] = mergedFilters.join(',');
    if (videoType.isNotEmpty) query['VideoTypes'] = videoType;
    if (searchTerm.trim().isNotEmpty) query['SearchTerm'] = searchTerm.trim();
    if (productionYear != null) query['Years'] = '$productionYear';
    return EmbyPcPage.fromJson(
      await _get('/emby/Users/$userId/Items', query: query),
    );
  }

  // 人物列表使用 Swagger 定义的 Persons 接口，避免受单个媒体库范围限制。
  Future<EmbyPcPage> getPersons({
    int startIndex = 0,
    int limit = 100,
    String searchTerm = '',
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    final query = <String, String>{
      'UserId': userId,
      'Recursive': 'true',
      // 人物 DTO 的 PremiereDate 保存出生日期，列表卡片据此显示出生年份。
      'Fields': 'Overview,PremiereDate,DateCreated,ProviderIds,SortName',
      'EnableUserData': 'true',
      'EnableImageTypes': 'Primary',
      'SortBy': sortBy,
      'SortOrder': sortOrder,
      'StartIndex': '$startIndex',
      'Limit': '${limit.clamp(1, 100)}',
    };
    if (searchTerm.trim().isNotEmpty) query['SearchTerm'] = searchTerm.trim();
    return EmbyPcPage.fromJson(await _get('/emby/Persons', query: query));
  }

  // Keep the continue-watching request aligned with Emby Web's Items/Resume endpoint.
  Future<EmbyPcPage> getResumeItems({
    int startIndex = 0,
    int? limit,
    String itemType = '',
    String searchTerm = '',
    int? productionYear,
    String sortBy = '',
    String sortOrder = '',
  }) async {
    final query = <String, String>{
      'Recursive': 'true',
      'MediaTypes': 'Video',
      'Fields':
          'BasicSyncInfo,CanDelete,CanDownload,PrimaryImageAspectRatio,'
          'ProgramPrimaryImageAspectRatio,ProductionYear,Status,EndDate',
      'ImageTypeLimit': '1',
      'EnableImageTypes': 'Primary,Backdrop,Thumb,Logo',
    };
    if (startIndex > 0) query['StartIndex'] = '$startIndex';
    if (limit != null) query['Limit'] = '${limit.clamp(1, 100)}';
    if (itemType.isNotEmpty) query['IncludeItemTypes'] = itemType;
    if (searchTerm.trim().isNotEmpty) query['SearchTerm'] = searchTerm.trim();
    if (productionYear != null) query['Years'] = '$productionYear';
    // DatePlayed descending is Emby Web's default Resume ordering.
    if (sortBy.isNotEmpty &&
        !(sortBy == 'DatePlayed' && sortOrder == 'Descending')) {
      query['SortBy'] = sortBy;
      if (sortOrder.isNotEmpty) query['SortOrder'] = sortOrder;
    }
    return EmbyPcPage.fromJson(
      await _get('/emby/Users/$userId/Items/Resume', query: query),
    );
  }

  Future<EmbyPcPage> searchItems(String searchTerm, {int limit = 60}) async {
    final queryText = searchTerm.trim();
    if (queryText.isEmpty) {
      return const EmbyPcPage(items: [], total: 0);
    }
    // 全局搜索省略 ParentId，让 Emby 从用户可访问的全部媒体库递归检索。
    return EmbyPcPage.fromJson(
      await _get(
        '/emby/Users/$userId/Items',
        query: {
          'SearchTerm': queryText,
          'Recursive': 'true',
          'IncludeItemTypes': 'Movie,Series,Video,Person',
          'Fields':
              'ProductionYear,PremiereDate,CommunityRating,RunTimeTicks,Width,Height',
          'EnableUserData': 'true',
          'EnableImageTypes': 'Primary,Backdrop',
          'StartIndex': '0',
          'Limit': '${limit.clamp(1, 100)}',
        },
      ),
    );
  }

  Future<EmbyPcItem> getItemDetail(String itemId) async {
    const fields =
        'Genres,Tags,Studios,People,MediaSources,Overview,Path,ProductionYear,'
        'PremiereDate,DateCreated,CommunityRating,OfficialRating,RunTimeTicks,'
        'Chapters,BackdropImageTags,ScreenshotImageTags';
    return EmbyPcItem.fromJson(
      await _get(
        '/emby/Users/$userId/Items/$itemId',
        query: {'Fields': fields, 'EnableUserData': 'true'},
      ),
    );
  }

  Future<Map<String, dynamic>> getItemForEditing(String itemId) async {
    const fields =
        'Genres,Tags,People,Overview,PremiereDate,DateCreated,CommunityRating,'
        'ProviderIds,OriginalTitle,SortName';
    // 保存时基于服务端 DTO 修改，避免未展示字段被空值覆盖。
    return Map<String, dynamic>.from(
      await _get(
        '/emby/Users/$userId/Items/$itemId',
        query: {'Fields': fields, 'EnableUserData': 'true'},
      ),
    );
  }

  Future<void> updateItemMetadata(
    String itemId,
    Map<String, dynamic> item,
  ) async {
    final response = await http.post(
      _uri('/emby/Items/$itemId'),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode(item),
    );
    _ensureSuccess(response, '保存元数据失败');
  }

  Future<EmbyPcItem> getPersonDetail(String personId) async {
    // 人物页需要外部编号、外部链接和摘要信息，统一随详情接口返回。
    const fields =
        'Overview,Genres,Tags,Studios,PremiereDate,DateCreated,SortName,'
        'ProviderIds,ExternalUrls';
    return EmbyPcItem.fromJson(
      await _get(
        '/emby/Users/$userId/Items/$personId',
        query: {'Fields': fields, 'EnableUserData': 'true'},
      ),
    );
  }

  Future<EmbyPcPage> getPersonItems(
    String personId, {
    int startIndex = 0,
  }) async {
    return EmbyPcPage.fromJson(
      await _get(
        '/emby/Users/$userId/Items',
        query: {
          'Recursive': 'true',
          'IncludeItemTypes': 'Movie,Series,Video,Episode',
          'PersonIds': personId,
          'Fields': 'ProductionYear,PremiereDate,CommunityRating',
          'EnableUserData': 'true',
          'SortBy': 'PremiereDate,SortName',
          'SortOrder': 'Descending',
          'StartIndex': '$startIndex',
          'Limit': '100',
        },
      ),
    );
  }

  Future<List<EmbyPcItem>> getSimilarItems(String itemId) async {
    final data = await _get(
      '/emby/Items/$itemId/Similar',
      query: {
        'UserId': userId,
        'Limit': '18',
        'Fields': 'ProductionYear,PremiereDate,CommunityRating',
      },
    );
    return EmbyPcPage.fromJson(data).items;
  }

  Future<bool> setFavorite(String itemId, bool favorite) async {
    final path = '/emby/Users/$userId/FavoriteItems/$itemId';
    final response = favorite
        ? await http.post(_uri(path), headers: _tokenHeader)
        : await http.delete(_uri(path), headers: _tokenHeader);
    final data = _decodeResponse(response, '更新收藏状态失败');
    return data['IsFavorite'] is bool ? data['IsFavorite'] as bool : favorite;
  }

  String imageUrl(
    String itemId, {
    String type = 'Primary',
    int index = 0,
    int maxWidth = 720,
    String cacheKey = '',
  }) {
    final path = type == 'Primary'
        ? '/emby/Items/$itemId/Images/Primary'
        : '/emby/Items/$itemId/Images/$type/$index';
    return _uri(path, {
      'api_key': accessToken,
      'maxWidth': '$maxWidth',
      'quality': '82',
      if (cacheKey.isNotEmpty) 'v': cacheKey,
    }).toString();
  }

  // 用户头像使用 Swagger 的 Users/{Id}/Images/{Type} 接口，请求当前登录用户的主图。
  String userAvatarUrl({int maxWidth = 96}) =>
      _uri('/emby/Users/$userId/Images/Primary', {
        'api_key': accessToken,
        'MaxWidth': '$maxWidth',
        'Quality': '82',
        // 上传后改变地址，避免 Flutter 的网络图片缓存继续显示旧头像。
        'v': '$_userAvatarRevision',
      }).toString();

  // 多版本播放通过 MediaSourceId 指定源，未指定时保持 Emby 默认选择。
  String streamUrl(String itemId, {String? mediaSourceId}) =>
      _uri('/emby/Videos/$itemId/stream', {
        'api_key': accessToken,
        'static': 'true',
        if (mediaSourceId != null && mediaSourceId.isNotEmpty)
          'mediaSourceId': mediaSourceId,
      }).toString();

  // Emby 预先生成的 BIF 文件包含进度条缩略图，加载失败时由播放器降级为普通进度条。
  Future<Uint8List?> getBifPreview(String itemId, {int width = 320}) async {
    try {
      final response = await http.get(
        _uri('/emby/Videos/$itemId/index.bif', {
          'api_key': accessToken,
          'Width': '$width',
        }),
        headers: _tokenHeader,
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  // 播放器使用同一个播放会话上报开始、进度和停止，Emby 才能可靠保存进度。
  Future<void> reportPlayback({
    required String itemId,
    required String mediaSourceId,
    required String playSessionId,
    required EmbyPcPlaybackEvent event,
    required int positionTicks,
    required bool paused,
    required bool muted,
    required int volumeLevel,
    required bool canSeek,
    String progressEventName = 'TimeUpdate',
  }) async {
    final eventPath = switch (event) {
      EmbyPcPlaybackEvent.started => '/emby/Sessions/Playing',
      EmbyPcPlaybackEvent.progress => '/emby/Sessions/Playing/Progress',
      EmbyPcPlaybackEvent.stopped => '/emby/Sessions/Playing/Stopped',
    };
    final body = <String, dynamic>{
      'ItemId': itemId,
      'UserId': userId,
      'MediaSourceId': mediaSourceId,
      'PlaySessionId': playSessionId,
      'PositionTicks': positionTicks,
      'IsPaused': paused,
      'IsMuted': muted,
      'VolumeLevel': volumeLevel,
      'CanSeek': canSeek,
      'PlayMethod': 'DirectPlay',
      'PlaybackRate': 1,
      // 只有停止接口使用 Failed；开始和进度接口不发送无关字段。
      if (event == EmbyPcPlaybackEvent.stopped) 'Failed': false,
      // EventName 属于进度请求，开始和停止请求不再固定伪装成 TimeUpdate。
      if (event == EmbyPcPlaybackEvent.progress)
        'EventName': progressEventName,
    };
    final response = await http.post(
      _uri(eventPath),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    // 输出接口和状态码，失败时继续抛出异常，由播放器记录具体原因。
    debugPrint(
      'Emby playback ${event.name}: $eventPath HTTP ${response.statusCode}',
    );
    _ensureSuccess(response, '播放状态上报失败（${event.name}）');
  }

  Future<EmbyPcPreferences> readPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    const validSortBy = {
      'CommunityRating',
      'Height',
      'DateCreated',
      'PremiereDate',
      'DatePlayed',
      'Runtime',
      'SortName',
    };
    final savedSortBy = prefs.getString(_sortByKey) ?? 'PremiereDate';
    final savedSortOrder = prefs.getString(_sortOrderKey) ?? 'Descending';
    return EmbyPcPreferences(
      sortBy: validSortBy.contains(savedSortBy) ? savedSortBy : 'PremiereDate',
      sortOrder: savedSortOrder == 'Ascending' ? 'Ascending' : 'Descending',
      imageStyle: prefs.getString(_imageStyleKey) ?? 'backdrop',
      libraryOrder: prefs.getStringList(_libraryOrderKey) ?? const [],
    );
  }

  Future<void> saveListPreferences({
    required String sortBy,
    required String sortOrder,
    required String imageStyle,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortByKey, sortBy);
    await prefs.setString(_sortOrderKey, sortOrder);
    await prefs.setString(_imageStyleKey, imageStyle);
  }

  Future<void> saveLibraryOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_libraryOrderKey, ids);
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await http.get(_uri(path, query), headers: _tokenHeader);
    return _decodeResponse(response, 'Emby 请求失败');
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$serverUrl$path').replace(queryParameters: query);

  Map<String, String> get _tokenHeader => {'X-Emby-Token': accessToken};

  String _responseText(http.Response response, String action) {
    _ensureSuccess(response, action);
    return response.bodyBytes.isEmpty
        ? ''
        : utf8.decode(response.bodyBytes).trim();
  }

  void _ensureSuccess(http.Response response, String action) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const EmbyPcException('登录已失效或当前账号没有管理权限');
    }
    throw EmbyPcException('$action：HTTP ${response.statusCode}');
  }

  Map<String, dynamic> _decodeResponse(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const EmbyPcException('登录已失效，请重新登录');
      }
      throw EmbyPcException('$action：HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.isEmpty) return <String, dynamic>{};
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    return _asMap(data);
  }

  static String normalizeServerUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.toLowerCase().endsWith('/emby')) {
      normalized = normalized.substring(0, normalized.length - 5);
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const EmbyPcException('请输入有效的 Emby 服务器地址');
    }
    return normalized;
  }
}

class EmbyPcSavedLogin {
  final String serverUrl;
  final String username;
  final String password;
  final bool rememberPassword;

  const EmbyPcSavedLogin({
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.rememberPassword,
  });
}

class EmbyPcPreferences {
  final String sortBy;
  final String sortOrder;
  final String imageStyle;
  final List<String> libraryOrder;

  const EmbyPcPreferences({
    required this.sortBy,
    required this.sortOrder,
    required this.imageStyle,
    required this.libraryOrder,
  });
}

class EmbyPcException implements Exception {
  final String message;

  const EmbyPcException(this.message);

  @override
  String toString() => message;
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
