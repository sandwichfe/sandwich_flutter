import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager extends ChangeNotifier {
  static final ThemeManager _instance = ThemeManager._();
  factory ThemeManager() => _instance;
  ThemeManager._();

  static const _keyBrightness = 'theme_brightness';
  static const _keySeedColor = 'theme_seed_color';

  Brightness _brightness = Brightness.dark;
  Color _seedColor = Colors.green;

  Brightness get brightness => _brightness;
  Color get seedColor => _seedColor;

  ThemeData get themeData => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: _seedColor, brightness: _brightness),
    brightness: _brightness,
    useMaterial3: true,
  );

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_keyBrightness) ?? true;
    final colorValue = prefs.getInt(_keySeedColor) ?? Colors.green.value;
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
