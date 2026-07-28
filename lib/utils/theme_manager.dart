import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager extends ChangeNotifier {
  static final ThemeManager _instance = ThemeManager._();
  factory ThemeManager() => _instance;
  ThemeManager._();

  static const _keyBrightness = 'theme_brightness';
  static const _keySeedColor = 'theme_seed_color';

  // 首次启动默认使用浅色模式和白色主题色（#fff）。
  Brightness _brightness = Brightness.light;
  Color _seedColor = Colors.white;

  Brightness get brightness => _brightness;
  Color get seedColor => _seedColor;

  ThemeData get themeData => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: _seedColor, brightness: _brightness),
    brightness: _brightness,
    useMaterial3: true,
  );

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_keyBrightness) ?? false;
    final colorValue = prefs.getInt(_keySeedColor) ?? Colors.white.value;
    _brightness = isDark ? Brightness.dark : Brightness.light;
    _seedColor = Color(colorValue);
    notifyListeners();
  }

  Future<void> setBrightness(Brightness brightness) async {
    _brightness = brightness;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBrightness, brightness == Brightness.dark);
  }

  Future<void> setSeedColor(Color color) async {
    _seedColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keySeedColor, color.value);
  }
}
