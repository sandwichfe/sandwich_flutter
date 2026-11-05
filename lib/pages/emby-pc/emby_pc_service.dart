import 'dart:async';
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

  // 全局复用同一个 Client：默认的 http.get/post 每次都新建连接，
  // 列表滚动时几十个图片/接口请求反复握手，桌面端体感明显。
  static final http.Client _client = _TimeoutClient(http.Client());

  // 401 集中拦截：任何请求发现令牌失效都自增这里，工作台监听后回到登录页。
  final ValueNotifier<int> unauthorizedRevision = ValueNotifier<int>(0);
  bool _expiringSession = false;

  static const _serverKey = 'emby_pc_server';
  static const _userIdKey = 'emby_pc_user_id';
  static const _tokenKey = 'emby_pc_token';
  static const _userNameKey = 'emby_pc_user_name';
  static const _userAvatarTagKey = 'emby_pc_user_avatar_tag';
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
  // 服务端下发的主图标记：为空表示该用户没设头像，客户端不必再请求图片。
  String currentUserAvatarTag = '';
  int _userAvatarRevision = 0;
  // 头像请求失败后置位，本次会话不再重试，避免每次重建都重复请求同一个 404 地址。
  bool _avatarUnavailable = false;

  // 头像状态变化（加载失败、上传成功）时通知界面重建，切换占位图标或新头像。
  final ValueNotifier<int> avatarRevision = ValueNotifier<int>(0);

  /// 是否值得发起头像请求：没有主图标记或本次会话已确认失败时返回 false。
  bool get hasUserAvatar =>
      currentUserAvatarTag.isNotEmpty && !_avatarUnavailable;

  bool get isLoggedIn => accessToken.isNotEmpty && userId.isNotEmpty;

  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString(_serverKey) ?? '';
    userId = prefs.getString(_userIdKey) ?? '';
    accessToken = prefs.getString(_tokenKey) ?? '';
    currentUserName = prefs.getString(_userNameKey) ?? '';
    // 旧版本没有存过标记（null）时先允许请求一次，避免已有头像的用户升级后看不到头像；
    // 明确存过空值才说明服务端确认该用户没有头像。
    currentUserAvatarTag = prefs.getString(_userAvatarTagKey) ?? 'unknown';
    // 冷启动时重新给头像一次机会，上次会话的失败不应永久生效。
    _avatarUnavailable = false;
  }

  Future<EmbyPcSavedLogin> readSavedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    return EmbyPcSavedLogin(
      // 不再回落硬编码地址：首次使用时由用户自己填写服务器。
      serverUrl: prefs.getString(_serverKey) ?? '',
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
    final response = await _client.post(
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
    // 登录响应带回主图标记，客户端据此决定是否请求头像图片。
    currentUserAvatarTag = user['PrimaryImageTag']?.toString() ?? '';
    _avatarUnavailable = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, serverUrl);
    await prefs.setString(_userIdKey, userId);
    await prefs.setString(_tokenKey, accessToken);
    await prefs.setString(_userNameKey, currentUserName);
    await prefs.setString(_userAvatarTagKey, currentUserAvatarTag);
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
    currentUserAvatarTag = '';
    _avatarUnavailable = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_userNameKey);
    await prefs.remove(_userAvatarTagKey);
  }

  Future<List<EmbyPcItem>> getLibraries() async {
    final data = await _get('/emby/Users/$userId/Views');
    return EmbyPcPage.fromJson(data).items;
  }

  Future<String> scanLibrary() async {
    final response = await _client.post(
      _uri('/emby/Library/Refresh'),
      headers: _tokenHeader,
    );
    return _responseText(response, '扫描媒体库失败');
  }

  // ---- 媒体库（VirtualFolders）管理 ----

  Future<List<EmbyPcVirtualFolder>> getVirtualFolders() async {
    final response = await _client.get(
      _uri('/emby/Library/VirtualFolders'),
      headers: _tokenHeader,
    );
    _ensureSuccess(response, '读取媒体库失败');
    if (response.bodyBytes.isEmpty) return const [];
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! List) throw const EmbyPcException('读取媒体库失败：响应格式错误');
    return data
        .whereType<Map>()
        .map((item) => EmbyPcVirtualFolder.fromJson(_asMap(item)))
        .toList();
  }

  // 后端以同名视为更新，因此新建与"保存"共用这一个入口。
  Future<void> createVirtualFolder({
    required String name,
    required String collectionType,
    required List<String> paths,
    bool preferLocalArtwork = true,
    bool refreshLibrary = true,
  }) async {
    final response = await _client.post(
      // paths 允许重复出现，Uri 的 queryParameters 支持可迭代值。
      _uri('/emby/Library/VirtualFolders', {
        'name': name.trim(),
        'collectionType': collectionType,
        'paths': paths,
        'preferLocalArtwork': '$preferLocalArtwork',
        'refreshLibrary': '$refreshLibrary',
      }),
      headers: _tokenHeader,
    );
    _ensureSuccess(response, '创建媒体库失败');
  }

  Future<void> updateVirtualFolder(
    String libraryId, {
    required String name,
    required String collectionType,
    required List<String> paths,
    bool? preferLocalArtwork,
  }) async {
    final response = await _client.put(
      _uri('/emby/Library/VirtualFolders/$libraryId'),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'Name': name.trim(),
        'CollectionType': collectionType,
        'Paths': paths,
        'PreferLocalArtwork': ?preferLocalArtwork,
      }),
    );
    _ensureSuccess(response, '保存媒体库失败');
  }

  // 只切换封面来源，不重传名称与目录，适合列表里就地开关。
  Future<void> setLibraryPreferLocalArtwork(
    String libraryId,
    bool preferLocal,
  ) async {
    final response = await _client.put(
      _uri('/emby/Library/VirtualFolders/$libraryId'),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({'PreferLocalArtwork': preferLocal}),
    );
    _ensureSuccess(response, '切换封面来源失败');
  }

  Future<void> renameVirtualFolder({
    required String name,
    required String newName,
  }) async {
    final response = await _client.post(
      _uri('/emby/Library/VirtualFolders/Name', {
        'name': name,
        'newName': newName.trim(),
      }),
      headers: _tokenHeader,
    );
    _ensureSuccess(response, '重命名媒体库失败');
  }

  Future<void> deleteVirtualFolder(String libraryId) async {
    final response = await _client.delete(
      _uri('/emby/Library/VirtualFolders', {'id': libraryId}),
      headers: _tokenHeader,
    );
    _ensureSuccess(response, '删除媒体库失败');
  }

  // ---- 整库批量生成海报/封面 ----

  // 只处理缺图的条目；force 为 true 时覆盖已有生成图。
  // positionRatio 为 0 表示自动嗅探画面，0.02~0.98 表示按各自片长的比例取帧。
  Future<EmbyPcArtworkJob> startArtworkJob(
    String libraryId, {
    bool force = false,
    List<String> types = const ['Primary', 'Backdrop'],
    double positionRatio = 0,
  }) async {
    final response = await _client.post(
      _uri('/emby/ArtworkJobs'),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'LibraryId': libraryId,
        'Force': force,
        'Types': types,
        'PositionRatio': positionRatio,
      }),
    );
    // 409 代表已有任务在跑，用明确文案代替通用状态码提示。
    if (response.statusCode == 409) {
      throw const EmbyPcException('已有海报生成任务在运行');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const EmbyPcException('登录已失效或当前账号没有管理权限');
    }
    // 其它失败（找不到 ffmpeg、库里都已有图等）由服务端返回中文原因。
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = _responseError(response);
      throw EmbyPcException(
        message.isEmpty ? '启动生成任务失败：HTTP ${response.statusCode}' : message,
      );
    }
    return EmbyPcArtworkJob.fromJson(
      _decodeResponse(response, '启动生成任务失败'),
    );
  }

  Future<EmbyPcArtworkJob> getArtworkJob(String jobId) async =>
      EmbyPcArtworkJob.fromJson(await _get('/emby/ArtworkJobs/$jobId'));

  Future<EmbyPcArtworkJob> cancelArtworkJob(String jobId) async {
    final response = await _client.post(
      _uri('/emby/ArtworkJobs/$jobId/Cancel'),
      headers: _tokenHeader,
    );
    final data = _decodeResponse(response, '取消生成任务失败');
    return EmbyPcArtworkJob.fromJson(data);
  }

  // ---- 进度条缩略图预生成 ----

  // 按媒体库批量生成 BIF 缩略图；任务在后台跑，返回初始进度快照。
  // force 为 false 时服务端会跳过已有同参数缓存的条目。
  Future<EmbyPcThumbnailJob> startThumbnailJob({
    required String libraryId,
    required int intervalSeconds,
    int width = 320,
    bool force = false,
  }) async {
    final response = await _client.post(
      _uri('/emby/ThumbnailJobs'),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'LibraryId': libraryId,
        'IntervalSeconds': intervalSeconds,
        'Width': width,
        'Force': force,
      }),
    );
    // 409 代表已有任务在跑，用明确文案代替通用的 HTTP 状态码提示。
    if (response.statusCode == 409) {
      throw const EmbyPcException('已有缩略图预生成任务在运行');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const EmbyPcException('登录已失效或当前账号没有管理权限');
    }
    // 其他失败（如找不到 ffmpeg）服务端会返回中文原因，直接透出便于定位。
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = _responseError(response);
      throw EmbyPcException(
        message.isEmpty ? '启动缩略图预生成失败：HTTP ${response.statusCode}' : message,
      );
    }
    final data = _decodeResponse(response, '启动缩略图预生成失败');
    return EmbyPcThumbnailJob.fromJson(data);
  }

  Future<List<EmbyPcThumbnailJob>> getThumbnailJobs() async {
    final response = await _client.get(
      _uri('/emby/ThumbnailJobs'),
      headers: _tokenHeader,
    );
    _ensureSuccess(response, '读取缩略图任务失败');
    if (response.bodyBytes.isEmpty) return const [];
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! List) throw const EmbyPcException('读取缩略图任务失败：响应格式错误');
    return data
        .whereType<Map>()
        .map((item) => EmbyPcThumbnailJob.fromJson(_asMap(item)))
        .toList();
  }

  Future<EmbyPcThumbnailJob> getThumbnailJob(String jobId) async {
    final data = await _get('/emby/ThumbnailJobs/$jobId');
    return EmbyPcThumbnailJob.fromJson(data);
  }

  Future<EmbyPcThumbnailJob> cancelThumbnailJob(String jobId) async {
    final response = await _client.post(
      _uri('/emby/ThumbnailJobs/$jobId/Cancel'),
      headers: _tokenHeader,
    );
    final data = _decodeResponse(response, '取消缩略图任务失败');
    return EmbyPcThumbnailJob.fromJson(data);
  }

  // 条目级刷新：后端发现 id 属于媒体库时直接触发该库扫描。
  Future<String> scanLibraryItem(String libraryId) async {
    final response = await _client.post(
      _uri('/emby/Items/$libraryId/Refresh', {'Recursive': 'true'}),
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
    final response = await _client.post(
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
    final response = await _client.get(
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
    final response = await _client.post(
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
    final response = await _client.post(
      _uri('/emby/Users/$userId/Images/Primary'),
      headers: {..._tokenHeader, 'Content-Type': contentType},
      // Swagger 要求用户图像正文使用 Base64 编码，和媒体图像上传规则一致。
      body: base64Encode(bytes),
    );
    _ensureSuccess(response, '上传头像失败');
    _userAvatarRevision++;
    // 服务端在新头像落盘后回传主图标记，用它解除失败记忆并刷新图片地址。
    final newTag = response.headers['x-primary-image-tag']?.trim() ?? '';
    currentUserAvatarTag = newTag.isNotEmpty
        ? newTag
        : 'local-$_userAvatarRevision';
    _avatarUnavailable = false;
    avatarRevision.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userAvatarTagKey, currentUserAvatarTag);
  }

  Future<void> deleteItemImage(
    String itemId, {
    required String type,
    required int index,
    String source = 'local',
  }) async {
    final response = await _client.delete(
      _uri('/emby/Items/$itemId/Images/$type/$index', {'Source': source}),
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
    // S3 新增的筛选条件：流派/演员按 ID 精确过滤，评分取“不低于”。
    List<String> genreIds = const [],
    List<String> personIds = const [],
    double? minCommunityRating,
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
    if (genreIds.isNotEmpty) query['GenreIds'] = genreIds.join(',');
    if (personIds.isNotEmpty) query['PersonIds'] = personIds.join(',');
    if (minCommunityRating != null) {
      query['MinCommunityRating'] = '$minCommunityRating';
    }
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

  // 流派候选值：S3 新增的聚合接口，Id 即名称，ChildCount 是条目数。
  // parentId 留空时统计全库，筛选栏默认按当前媒体库取。
  Future<List<EmbyPcItem>> getGenres({String parentId = ''}) async {
    final data = await _get(
      '/emby/Genres',
      query: {if (parentId.isNotEmpty) 'ParentId': parentId},
    );
    return EmbyPcPage.fromJson(data).items;
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

  Future<EmbyPcPage> searchItems(
    String searchTerm, {
    int limit = 60,
    int startIndex = 0,
  }) async {
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
          'StartIndex': '$startIndex',
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

  // 按需读取指定媒体版本的播放信息，避免切换版本时直接启动播放器。
  Future<EmbyPcMediaSource?> getMediaSourceInfo({
    required String itemId,
    required String mediaSourceId,
  }) async {
    final response = await _client.post(
      _uri('/emby/Items/$itemId/PlaybackInfo'),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'Id': itemId,
        'UserId': userId,
        'MediaSourceId': mediaSourceId,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': false,
        'IsPlayback': false,
      }),
    );
    final data = _decodeResponse(response, '读取媒体版本信息失败');
    final rawSources = data['MediaSources'];
    final sources = rawSources is List
        ? rawSources
              .whereType<Map>()
              .map(
                (value) => EmbyPcMediaSource.fromJson(
                  Map<String, dynamic>.from(value),
                ),
              )
              .toList()
        : <EmbyPcMediaSource>[];
    for (final source in sources) {
      if (source.id == mediaSourceId) return source;
    }
    return sources.isEmpty ? null : sources.first;
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
    final response = await _client.post(
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
    int limit = 100,
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
          'Limit': '${limit.clamp(1, 100)}',
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
        ? await _client.post(_uri(path), headers: _tokenHeader)
        : await _client.delete(_uri(path), headers: _tokenHeader);
    final data = _decodeResponse(response, '更新收藏状态失败');
    return data['IsFavorite'] is bool ? data['IsFavorite'] as bool : favorite;
  }

  // source 留空时由服务端按条目所属媒体库的偏好决定读目录图还是生成图；
  // 传 local/generated 则强制指定，图像编辑弹窗预览用。
  String imageUrl(
    String itemId, {
    String type = 'Primary',
    int index = 0,
    int maxWidth = 720,
    String cacheKey = '',
    String? source,
  }) {
    final path = type == 'Primary'
        ? '/emby/Items/$itemId/Images/Primary'
        : '/emby/Items/$itemId/Images/$type/$index';
    return _uri(path, {
      'api_key': accessToken,
      'maxWidth': '$maxWidth',
      'quality': '82',
      if (source != null && source.isNotEmpty) 'Source': source,
      if (cacheKey.isNotEmpty) 'v': cacheKey,
    }).toString();
  }

  // 带内容标签的条目图片地址：服务端换图后 tag 变化 → URL 变化 →
  // Flutter 的图片缓存自然失效，不需要重启客户端（S5.8）。
  String imageUrlForItem(
    EmbyPcItem item, {
    String type = 'Primary',
    int index = 0,
    int maxWidth = 720,
  }) {
    final tag = switch (type) {
      'Primary' =>
        item.primaryImageTag.isNotEmpty
            ? item.primaryImageTag
            : item.imageTags['Primary']?.toString() ?? '',
      'Backdrop' =>
        index < item.backdropImageTags.length
            ? item.backdropImageTags[index]
            : '',
      _ => item.imageTags[type]?.toString() ?? '',
    };
    return imageUrl(
      item.id,
      type: type,
      index: index,
      maxWidth: maxWidth,
      cacheKey: tag,
    );
  }

  // 人物头像同样带标签：演员头像被替换后，卡片地址随之变化。
  String imageUrlForPerson(EmbyPcPerson person, {int maxWidth = 520}) => imageUrl(
    person.id,
    maxWidth: maxWidth,
    cacheKey: person.primaryImageTag.isNotEmpty
        ? person.primaryImageTag
        : person.imageTags['Primary']?.toString() ?? '',
  );

  // 从视频画面生成海报/封面：positionTicks 为 0 时由服务端自动嗅探画面。
  Future<EmbyPcArtworkGeneration> generateArtwork(
    String itemId, {
    required bool sniff,
    required int positionTicks,
    List<String> types = const ['Primary', 'Backdrop'],
    int width = 0,
  }) async {
    final response = await _client.post(
      _uri('/emby/Items/$itemId/Images/Generate'),
      headers: {..._tokenHeader, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'Types': types,
        'PositionTicks': sniff ? 0 : positionTicks,
        'Width': width,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 抽帧失败原因（缺少 ffmpeg、时间点超界等）由服务端用中文返回，直接透出。
      final message = _responseError(response);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const EmbyPcException('登录已失效或当前账号没有管理权限');
      }
      throw EmbyPcException(
        message.isEmpty ? '生成封面失败：HTTP ${response.statusCode}' : message,
      );
    }
    return EmbyPcArtworkGeneration.fromJson(
      _decodeResponse(response, '生成封面失败'),
    );
  }

  // 用户头像使用 Swagger 的 Users/{Id}/Images/{Type} 接口，请求当前登录用户的主图。
  // 没有主图标记或本次会话已确认加载失败时返回 null，界面直接显示占位图标，
  // 避免每次重建都去向一个必然 404 的地址发请求。
  String? userAvatarUrl({int maxWidth = 96}) {
    if (!hasUserAvatar) return null;
    return _uri('/emby/Users/$userId/Images/Primary', {
      'api_key': accessToken,
      'MaxWidth': '$maxWidth',
      'Quality': '82',
      // 上传后改变地址，避免 Flutter 的网络图片缓存继续显示旧头像。
      'v': '$_userAvatarRevision',
    }).toString();
  }

  // 头像加载失败后由界面回调触发：本次会话不再重试，直到重新登录或上传新头像。
  void markUserAvatarUnavailable() {
    if (_avatarUnavailable) return;
    _avatarUnavailable = true;
    avatarRevision.value++;
  }

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
      final response = await _client.get(
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
    // 播放倍速：服务端据此统计实际观看时长（S5.7）。
    double playbackRate = 1,
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
      'PlaybackRate': playbackRate,
      // 只有停止接口使用 Failed；开始和进度接口不发送无关字段。
      if (event == EmbyPcPlaybackEvent.stopped) 'Failed': false,
      // EventName 属于进度请求，开始和停止请求不再固定伪装成 TimeUpdate。
      if (event == EmbyPcPlaybackEvent.progress) 'EventName': progressEventName,
    };
    final response = await _client.post(
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

  // 设置页修改服务器地址：旧令牌属于旧服务器，保存后立即清掉会话回到登录页。
  Future<void> updateServerUrl(String server) async {
    final normalized = normalizeServerUrl(server);
    serverUrl = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, normalized);
    if (isLoggedIn) await logout();
  }

  // 媒体库扫描的实时进度（管理员）：服务端维护计数，客户端不再靠条目数猜测。
  Future<EmbyPcScanStatus> getScanStatus() async =>
      EmbyPcScanStatus.fromJson(await _get('/emby/Library/ScanStatus'));

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _client.get(_uri(path, query), headers: _tokenHeader);
    return _decodeResponse(response, 'Emby 请求失败');
  }

  // 值支持 Iterable<String>，用于 paths 这类需要重复同名参数的接口。
  Uri _uri(String path, [Map<String, dynamic>? query]) =>
      Uri.parse('$serverUrl$path').replace(queryParameters: query);

  Map<String, String> get _tokenHeader => {'X-Emby-Token': accessToken};

  // 服务端错误体统一为 {"message": "..."}；取不到时退回原始文本，
  // 兼容旧版本返回的纯文本错误。
  String _responseError(http.Response response) {
    if (response.bodyBytes.isEmpty) return '';
    final text = utf8.decode(response.bodyBytes).trim();
    try {
      final data = jsonDecode(text);
      if (data is Map && data['message'] is String) {
        return (data['message'] as String).trim();
      }
    } catch (_) {
      // 不是 JSON，按纯文本处理。
    }
    return text;
  }

  String _responseText(http.Response response, String action) {
    _ensureSuccess(response, action);
    return response.bodyBytes.isEmpty
        ? ''
        : utf8.decode(response.bodyBytes).trim();
  }

  // 令牌失效统一处理：清会话并通知界面，多个并发请求只触发一次。
  void _notifyUnauthorized() {
    if (_expiringSession || !isLoggedIn) return;
    _expiringSession = true;
    unawaited(
      logout().whenComplete(() {
        _expiringSession = false;
        unauthorizedRevision.value++;
      }),
    );
  }

  void _ensureSuccess(http.Response response, String action) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401) {
      _notifyUnauthorized();
      throw const EmbyPcException('登录已失效，请重新登录');
    }
    if (response.statusCode == 403) {
      throw const EmbyPcException('当前账号没有管理权限');
    }
    final message = _responseError(response);
    throw EmbyPcException(
      message.isEmpty ? '$action：HTTP ${response.statusCode}' : message,
    );
  }

  Map<String, dynamic> _decodeResponse(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401) {
        _notifyUnauthorized();
        throw const EmbyPcException('登录已失效，请重新登录');
      }
      if (response.statusCode == 403) {
        throw const EmbyPcException('当前账号没有管理权限');
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

// 所有请求共用同一份超时策略：服务器离线或网络盘卡住时不再无限等待。
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(this._inner);

  final http.Client _inner;
  static const Duration _timeout = Duration(seconds: 15);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request).timeout(
        _timeout,
        onTimeout: () => throw const EmbyPcException('请求超时，请检查服务器连接'),
      );
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
