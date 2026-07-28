import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager extends ChangeNotifier {
  static final ThemeManager _instance = ThemeManager._();
  factory ThemeManager() => _instance;
  ThemeManager._();

  static const _keyBrightness = 'theme_brightness';
  static const _keySeedColor = 'theme_seed_color';
  static const _keyBackgroundColor = 'theme_background_color';

  // 首次启动使用低饱和靛蓝，保持媒体页面操作色克制且易于识别。
  Brightness _brightness = Brightness.light;
  Color _seedColor = const Color(0xFF5965A8);
  // 背景色独立于主题色；未自定义时沿用系统常见的明暗模式背景。
  Color? _backgroundColor;

  Brightness get brightness => _brightness;
  Color get seedColor => _seedColor;
  Color get backgroundColor =>
      _backgroundColor ??
      (_brightness == Brightness.dark
          ? const Color(0xFF111318)
          : const Color(0xFFF5F6F8));

  /// 从用户选择的画布色派生表面层，避免自定义背景后页面层级再次被压平。
  Color _shiftSurface(Color base, double lightnessOffset) {
    final hsl = HSLColor.fromColor(base);
    return hsl
        .withLightness((hsl.lightness + lightnessOffset).clamp(0.0, 1.0))
        .toColor();
  }

  ThemeData get themeData {
    final generatedScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: _brightness,
    );
    final isDark = _brightness == Brightness.dark;
    final canvas = backgroundColor;
    final customCanvasIsNearWhite =
        _backgroundColor != null && HSLColor.fromColor(canvas).lightness > 0.9;
    final chrome =
        _backgroundColor == null
            ? (isDark ? const Color(0xFF171A20) : const Color(0xFFFAFBFC))
            : _shiftSurface(
              canvas,
              customCanvasIsNearWhite ? -0.04 : (isDark ? 0.035 : 0.022),
            );
    final card =
        _backgroundColor == null
            ? (isDark ? const Color(0xFF1D2027) : Colors.white)
            : _shiftSurface(
              canvas,
              customCanvasIsNearWhite ? -0.018 : (isDark ? 0.065 : 0.05),
            );
    final border =
        _backgroundColor == null
            ? (isDark ? const Color(0xFF30343D) : const Color(0xFFE2E5EA))
            : Color.alphaBlend(
              generatedScheme.onSurface.withValues(alpha: isDark ? 0.18 : 0.12),
              card,
            );
    // 画布、应用栏和卡片分别落在三层表面色上，菜单沿用最上层卡片色。
    final colorScheme = generatedScheme.copyWith(
      surface: card,
      surfaceContainerLowest: canvas,
      surfaceContainerLow: chrome,
      surfaceContainer: canvas,
      surfaceContainerHigh: chrome,
      outline: border,
      outlineVariant: border,
      onSurface: isDark ? const Color(0xFFF0F1F4) : const Color(0xFF17191F),
      onSurfaceVariant:
          isDark ? const Color(0xFFAEB3BE) : const Color(0xFF656B76),
    );
    return ThemeData(
      colorScheme: colorScheme,
      brightness: _brightness,
      scaffoldBackgroundColor: canvas,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Microsoft YaHei UI'],
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
        bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
      ),
      // 顶部导航使用中间表面层，与页面画布和菜单卡片形成稳定层级。
      appBarTheme: AppBarTheme(
        backgroundColor: chrome,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(card),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border),
        ),
      ),
      useMaterial3: true,
    );
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_keyBrightness) ?? false;
    final colorValue =
        prefs.getInt(_keySeedColor) ?? const Color(0xFF5965A8).value;
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
