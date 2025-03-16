import 'package:shared_preferences/shared_preferences.dart';

class StorageUtil {
  static SharedPreferences? _preferences;

  // 初始化方法
  static Future<void> init() async {
    _preferences = await SharedPreferences.getInstance();
  }

  // 保存token
  static Future<bool> saveToken(String token) async {
    return await _preferences?.setString('token', token) ?? false;
  }

  // 获取token
  static String? getToken() {
    return _preferences?.getString('token');
  }

  // 清除token
  static Future<bool> removeToken() async {
    return await _preferences?.remove('token') ?? false;
  }
} 