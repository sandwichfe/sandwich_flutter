import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager extends ChangeNotifier {
  static final ThemeManager _instance = ThemeManager._();
  factory ThemeManager() => _instance;
  ThemeManager._();

  static const _keyBrightness = 'theme_brightness';
  static const _keySeedColor = 'theme_seed_color';
  static const _keyBackgroundColor = 'theme_background_color';

  // 首次启动默认使用浅色模式和白色主题色（#fff）。
  Brightness _brightness = Brightness.light;
  Color _seedColor = Colors.white;
  // 背景色独立于主题色；未自定义时沿用系统常见的明暗模式背景。
  Color? _backgroundColor;

  Brightness get brightness => _brightness;
  Color get seedColor => _seedColor;
  Color get backgroundColor =>
      _backgroundColor ??
      (_brightness == Brightness.dark ? const Color(0xFF121212) : Colors.white);

  ThemeData get themeData => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: _seedColor, brightness: _brightness),
    brightness: _brightness,
    scaffoldBackgroundColor: backgroundColor,
    useMaterial3: true,
  );

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_keyBrightness) ?? false;
    final colorValue = prefs.getInt(_keySeedColor) ?? Colors.white.value;
    final backgroundValue = prefs.getInt(_keyBackgroundColor);
    _brightness = isDark ? Brightness.dark : Brightness.light;
    _seedColor = Color(colorValue);
    _backgroundColor = backgroundValue == null ? null : Color(backgroundValue);
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

  // 背景色单独保存，避免修改主题色时改变页面底色。
  Future<void> setBackgroundColor(Color color) async {
    _backgroundColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyBackgroundColor, color.value);
  }
}
