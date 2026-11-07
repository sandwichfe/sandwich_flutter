import 'package:flutter/material.dart';

/// Emby PC 工作台的视觉皮肤。
///
/// 影音工作台与普通设置页的观感不同：使用更深、更沉浸的画布，
/// 强调色用渐变表达，卡片统一大圆角。这里集中管理这些 token，
/// 页面层只引用语义色，不再散落具体的十六进制颜色。
class EmbyPcSkin {
  const EmbyPcSkin._(this.scheme, this.dark);

  final ColorScheme scheme;
  final bool dark;

  factory EmbyPcSkin.of(BuildContext context) {
    final theme = Theme.of(context);
    return EmbyPcSkin._(theme.colorScheme, theme.brightness == Brightness.dark);
  }

  Color get accent => scheme.primary;

  // 影院画布：深色模式下接近纯黑，浅色模式下改为带蓝调的浅灰。
  Color get canvas => dark ? const Color(0xFF080A0D) : const Color(0xFFF4F5F8);
  Color get sidebar => dark ? const Color(0xFF0C0F14) : Colors.white;
  Color get surface => dark ? const Color(0xFF14181F) : Colors.white;
  Color get surfaceAlt =>
      dark ? const Color(0xFF1C2129) : const Color(0xFFEDF0F4);
  Color get hairline =>
      dark ? const Color(0x14FFFFFF) : const Color(0xFFE3E6EC);
  Color get textSecondary =>
      dark ? const Color(0xFF9BA5B4) : const Color(0xFF646B78);
  Color get textTertiary =>
      dark ? const Color(0xFF6F7A89) : const Color(0xFF98A0AC);

  Color tint(double alpha) => accent.withValues(alpha: alpha);

  LinearGradient get accentFill => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      accent,
      Color.alphaBlend(Colors.white.withValues(alpha: 0.32), accent),
    ],
  );

  // 侧栏选中项：由强调色向右淡出，像视频软件的高亮导航条。
  LinearGradient get navActiveFill => LinearGradient(
    colors: [
      accent.withValues(alpha: dark ? 0.30 : 0.18),
      accent.withValues(alpha: 0.02),
    ],
  );

  LinearGradient get brandGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color.alphaBlend(Colors.white.withValues(alpha: 0.18), accent),
      Color.alphaBlend(const Color(0xFF3A1D6E), accent),
    ],
  );

  /// 只在工作台内部生效的主题：更大圆角、更柔和的控件与菜单。
  static ThemeData themeDataOf(BuildContext context) {
    final base = Theme.of(context);
    final skin = EmbyPcSkin.of(context);
    final scheme = base.colorScheme.copyWith(
      surface: skin.surface,
      surfaceContainerLowest: skin.canvas,
      surfaceContainerLow: skin.sidebar,
      surfaceContainer: skin.canvas,
      surfaceContainerHigh: skin.surfaceAlt,
      surfaceContainerHighest: skin.dark
          ? const Color(0xFF262C36)
          : const Color(0xFFE4E8EE),
      outline: skin.hairline,
      outlineVariant: skin.hairline,
    );
    final textTheme = base.textTheme.copyWith(
      headlineSmall: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      titleLarge: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      titleMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      bodyMedium: const TextStyle(fontSize: 14, height: 1.45),
      bodySmall: TextStyle(fontSize: 12, color: skin.textSecondary),
    );
    return base
        .copyWith(
          colorScheme: scheme,
          scaffoldBackgroundColor: skin.canvas,
          canvasColor: skin.canvas,
          textTheme: textTheme,
          dividerTheme: DividerThemeData(
            color: skin.hairline,
            thickness: 1,
            space: 1,
          ),
          scrollbarTheme: ScrollbarThemeData(
            thickness: const WidgetStatePropertyAll(6),
            radius: const Radius.circular(3),
            thumbColor: WidgetStatePropertyAll(skin.tint(0.35)),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              foregroundColor: scheme.onSurface,
              side: BorderSide(color: skin.hairline),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: skin.accent,
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: skin.surfaceAlt,
            isDense: true,
            hintStyle: TextStyle(fontSize: 13, color: skin.textTertiary),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: skin.hairline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: skin.hairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: skin.accent, width: 1.4),
            ),
          ),
          popupMenuTheme: PopupMenuThemeData(
            color: skin.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 18,
            shadowColor: Colors.black.withValues(alpha: 0.45),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: skin.hairline),
            ),
            textStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
          ),
          menuTheme: MenuThemeData(
            style: MenuStyle(
              backgroundColor: WidgetStatePropertyAll(skin.surface),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              elevation: const WidgetStatePropertyAll(18),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: skin.hairline),
                ),
              ),
            ),
          ),
          chipTheme: ChipThemeData(
            backgroundColor: skin.surfaceAlt,
            selectedColor: skin.tint(0.18),
            side: BorderSide(color: skin.hairline),
            shape: const StadiumBorder(),
            labelStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          tooltipTheme: TooltipThemeData(
            decoration: BoxDecoration(
              color: skin.dark
                  ? const Color(0xFF232A35)
                  : const Color(0xFF2B303A),
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontSize: 12, color: Colors.white),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: skin.surface,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: skin.hairline),
            ),
          ),
        )
        .copyWith(extensions: base.extensions.values);
  }
}

/// 工作台统一的影院背景：顶部一抹强调色光晕 + 纵向渐隐。
class EmbyPcBackdrop extends StatelessWidget {
  final Widget child;

  const EmbyPcBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(skin.tint(skin.dark ? 0.16 : 0.10), skin.canvas),
            skin.canvas,
            skin.canvas,
          ],
          stops: const [0, 0.42, 1],
        ),
      ),
      child: child,
    );
  }
}
