import 'dart:async';

import 'package:flutter/material.dart';

enum EmbyPcToastType { info, success, error }

class EmbyPcToast {
  // 全应用同一时刻只保留一条提示，后续消息会替换前一条消息。
  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;

  static void show(
    BuildContext context,
    String message, {
    EmbyPcToastType type = EmbyPcToastType.info,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _removeCurrent();
    final entry = OverlayEntry(
      builder: (_) => _EmbyPcToastView(message: message, type: type),
    );
    _currentEntry = entry;
    overlay.insert(entry);
    _dismissTimer = Timer(
      Duration(seconds: type == EmbyPcToastType.error ? 4 : 2),
      () {
        if (_currentEntry == entry) _removeCurrent();
      },
    );
  }

  static void _removeCurrent() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _EmbyPcToastView extends StatelessWidget {
  final String message;
  final EmbyPcToastType type;

  const _EmbyPcToastView({required this.message, required this.type});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, backgroundColor, foregroundColor) = switch (type) {
      EmbyPcToastType.success => (
        Icons.check_circle_outline,
        colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
      ),
      EmbyPcToastType.error => (
        Icons.error_outline,
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
      EmbyPcToastType.info => (
        Icons.info_outline,
        colorScheme.secondaryContainer,
        colorScheme.onSecondaryContainer,
      ),
    };

    // Toast 固定显示在安全区域下方，避免遮挡系统状态栏和页面主操作区。
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                tween: Tween(begin: 0, end: 1),
                builder: (context, value, child) => Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, -8 * (1 - value)),
                    child: child,
                  ),
                ),
                child: Material(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(6),
                  elevation: 6,
                  child: Semantics(
                    liveRegion: true,
                    label: message,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, color: foregroundColor, size: 20),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              message,
                              style: TextStyle(color: foregroundColor),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
