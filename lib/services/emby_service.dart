import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emby_models.dart';

class EmbyService {
  static final EmbyService _instance = EmbyService._();
  factory EmbyService() => _instance;
  EmbyService._();

  final EmbyConfig config = EmbyConfig();

  static const _kServer = 'emby_server';
  static const _kUserId = 'emby_uid';
  static const _kToken = 'emby_token';
  static const _kDeviceId = 'emby_device_id';
  static const _kIsJellyfin = 'emby_is_jellyfin';

  bool get isLoggedIn => config.token.isNotEmpty && config.userId.isNotEmpty;

  Future<void> loadFromStorage() async {
    final p = await SharedPreferences.getInstance();
    config.server = p.getString(_kServer) ?? '';
    config.userId = p.getString(_kUserId) ?? '';
    config.token = p.getString(_kToken) ?? '';
    config.deviceId = p.getString(_kDeviceId) ?? _generateDeviceId();
    config.isJellyfin = p.getBool(_kIsJellyfin) ?? false;
  }

  Future<void> _saveToStorage() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kServer, config.server);
    await p.setString(_kUserId, config.userId);
    await p.setString(_kToken, config.token);
    await p.setString(_kDeviceId, config.deviceId);
    await p.setBool(_kIsJellyfin, config.isJellyfin);
  }

  Future<void> logout() async {
    config.token = '';
    config.userId = '';
    await _saveToStorage();
  }

  String _generateDeviceId() {
    final id = 'EmbyX-${DateTime.now().millisecondsSinceEpoch}';
    config.deviceId = id;
    return id;
  }

  Map<String, String> get _authHeader => {
        'X-Emby-Authorization':
            'Emby Client="EmbyX", Device="FlutterApp", DeviceId="${config.deviceId}", Version="1.0", Token="${config.token}"',
        'Content-Type': 'application/json',
      };

  String _url(String path) {
    final base = config.server.endsWith('/') ? config.server.substring(0, config.server.length - 1) : config.server;
    final prefix = config.isJellyfin ? '' : '/emby';
    return '$base$prefix$path';
  }

  Future<String> login(String server, String username, String password) async {
    config.server = server.endsWith('/') ? server.substring(0, server.length - 1) : server;
    if (config.deviceId.isEmpty) _generateDeviceId();

    // Detect Jellyfin
    try {
      final info = await http.get(Uri.parse('${config.server}/System/Info/Public'));
      if (info.statusCode == 200) {
        final body = jsonDecode(info.body);
        config.isJellyfin = (body['ProductName'] ?? '').toString().toLowerCase().contains('jellyfin');
      }
    } catch (_) {}

    final url = _url('/Users/AuthenticateByName');
    final resp = await http.post(
      Uri.parse(url),
      headers: {
        'X-Emby-Authorization':
            'Emby Client="EmbyX", Device="FlutterApp", DeviceId="${config.deviceId}", Version="1.0"',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'Username': username, 'Pw': password}),
    );

    if (resp.statusCode != 200) throw Exception('登录失败: ${resp.statusCode}');

    final data = jsonDecode(resp.body);
    config.token = data['AccessToken'] ?? '';
    config.userId = data['SessionInfo']?['UserId'] ?? data['User']?['Id'] ?? '';
    await _saveToStorage();
    return config.userId;
  }

  Future<List<EmbyLibrary>> getLibraries() async {
    final url = _url('/Users/${config.userId}/Items?IncludeItemTypes=CollectionFolder&api_key=${config.token}');
    final resp = await http.get(Uri.parse(url), headers: _authHeader);
    if (resp.statusCode != 200) throw Exception('获取媒体库失败');
    final data = jsonDecode(resp.body);
    return (data['Items'] as List).map((e) => EmbyLibrary.fromJson(e)).toList();
  }

  Future<({List<EmbyItem> items, int total})> getItems({
    String? parentId,
    int limit = 150,
    int startIndex = 0,
    String sortBy = 'DateCreated',
    String? searchTerm,
  }) async {
    var url = _url(
        '/Users/${config.userId}/Items?api_key=${config.token}'
        '&Recursive=true'
        '&IncludeItemTypes=Movie,Episode,Video,MusicVideo'
        '&Fields=Overview,RunTimeTicks,UserData'
        '&Limit=$limit&StartIndex=$startIndex'
        '&SortBy=$sortBy&SortOrder=Descending');
    if (parentId != null) url += '&ParentId=$parentId';
    final keyword = searchTerm?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      url += '&SearchTerm=${Uri.encodeQueryComponent(keyword)}';
    }

    final resp = await http.get(Uri.parse(url), headers: _authHeader);
    if (resp.statusCode != 200) throw Exception('获取视频列表失败');
    final data = jsonDecode(resp.body);
    final items = (data['Items'] as List).map((e) => EmbyItem.fromJson(e)).toList();
    return (items: items, total: data['TotalRecordCount'] as int);
  }

  Future<void> setFavorite(String itemId, {required bool favorite}) async {
    final url = _url('/Users/${config.userId}/FavoriteItems/$itemId?api_key=${config.token}');
    if (favorite) {
      await http.post(Uri.parse(url), headers: _authHeader);
    } else {
      await http.delete(Uri.parse(url), headers: _authHeader);
    }
  }

  Future<({List<EmbyItem> items, int total})> getFavorites({int limit = 150, int startIndex = 0}) async {
    var url = _url('/Users/${config.userId}/Items?api_key=${config.token}'
        '&Recursive=true'
        '&Filters=IsFavorite'
        '&IncludeItemTypes=Movie,Episode,Video,MusicVideo'
        '&Fields=Overview,RunTimeTicks,UserData'
        '&Limit=$limit&StartIndex=$startIndex'
        '&SortBy=DateCreated&SortOrder=Descending');
    final resp = await http.get(Uri.parse(url), headers: _authHeader);
    if (resp.statusCode != 200) throw Exception('获取收藏失败');
    final data = jsonDecode(resp.body);
    final items = (data['Items'] as List).map((e) => EmbyItem.fromJson(e)).toList();
    return (items: items, total: data['TotalRecordCount'] as int);
  }

  String getStreamUrl(String itemId) =>
      _url('/Videos/$itemId/stream?api_key=${config.token}&static=true');

  String getThumbnailUrl(String itemId) =>
      _url('/Items/$itemId/Images/Primary?api_key=${config.token}&maxHeight=400');
}
