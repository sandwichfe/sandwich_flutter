import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'emby_pc_models.dart';

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
    final types = const {'Movie', 'Series', 'Video', 'Person'}.contains(itemType)
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

  Future<EmbyPcItem> getItemDetail(String itemId) async {
    const fields =
        'Genres,Tags,Studios,People,MediaSources,Overview,Path,ProductionYear,'
        'PremiereDate,DateCreated,CommunityRating,OfficialRating,RunTimeTicks,'
        'Chapters,BackdropImageTags,ScreenshotImageTags';
    return EmbyPcItem.fromJson(
      await _get('/emby/Users/$userId/Items/$itemId', query: {
        'Fields': fields,
        'EnableUserData': 'true',
      }),
    );
  }

  Future<EmbyPcItem> getPersonDetail(String personId) async {
    // 人物页需要外部编号、外部链接和摘要信息，统一随详情接口返回。
    const fields =
        'Overview,Genres,Tags,Studios,PremiereDate,DateCreated,SortName,'
        'ProviderIds,ExternalUrls';
    return EmbyPcItem.fromJson(
      await _get('/emby/Users/$userId/Items/$personId', query: {
        'Fields': fields,
        'EnableUserData': 'true',
      }),
    );
  }

  Future<EmbyPcPage> getPersonItems(String personId, {int startIndex = 0}) async {
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
  }) {
    final path = type == 'Primary'
        ? '/emby/Items/$itemId/Images/Primary'
        : '/emby/Items/$itemId/Images/$type/$index';
    return _uri(path, {
      'api_key': accessToken,
      'maxWidth': '$maxWidth',
      'quality': '82',
    }).toString();
  }

  String streamUrl(String itemId) => _uri(
    '/emby/Videos/$itemId/stream',
    {'api_key': accessToken, 'static': 'true'},
  ).toString();

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

  // 播放器周期性上报位置，Emby 才能在下次打开时计算“继续播放”。
  Future<void> reportPlayback({
    required String itemId,
    required String eventPath,
    required int positionTicks,
    required bool paused,
  }) async {
    try {
      final response = await http.post(
        _uri('/emby$eventPath'),
        headers: {..._tokenHeader, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'ItemId': itemId,
          'UserId': userId,
          'PositionTicks': positionTicks,
          'IsPaused': paused,
          'IsMuted': false,
          'PlayMethod': 'DirectPlay',
          'EventName': 'TimeUpdate',
        }),
      );
      // 进度上报失败不能影响本地播放，因此只忽略非成功响应。
      if (response.statusCode < 200 || response.statusCode >= 300) return;
    } catch (_) {}
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
