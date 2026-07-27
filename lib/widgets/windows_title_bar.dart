import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 桌面端的全局窗口框架，提供精简标题栏和原生窗口操作。
class WindowsTitleBar extends StatefulWidget {
  final Widget child;

  const WindowsTitleBar({super.key, required this.child});

  @override
  State<WindowsTitleBar> createState() => _WindowsTitleBarState();
}

class _WindowsTitleBarState extends State<WindowsTitleBar>
    with WindowListener {
  bool _isMaximized = false;
  bool _isFullScreen = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncWindowState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 同步窗口初始状态，避免热重载或恢复窗口后图标显示不准确。
  Future<void> _syncWindowState() async {
    final isMaximized = await windowManager.isMaximized();
    final isFullScreen = await windowManager.isFullScreen();
    if (!mounted) return;
    setState(() {
      _isMaximized = isMaximized;
      _isFullScreen = isFullScreen;
    });
  }

  /// 在最大化和普通窗口之间切换，并及时更新还原按钮状态。
  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _syncWindowState();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  void onWindowRestore() {
    _syncWindowState();
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted) setState(() => _isFullScreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted) setState(() => _isFullScreen = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 标题栏与下方内容统一使用表面色，避免出现背景色断层。
    final titleBarColor = colors.surface;

    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: [
          if (!_isFullScreen)
            _TitleBar(
              color: titleBarColor,
              isMaximized: _isMaximized,
              onToggleMaximize: _toggleMaximize,
            ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  final Color color;
  final bool isMaximized;
  final VoidCallback onToggleMaximize;

  const _TitleBar({
    required this.color,
    required this.isMaximized,
    required this.onToggleMaximize,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: color,
      // 不绘制底部分隔线，让标题栏直接融入下方内容。
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              // 拖动区只覆盖标题部分，不会拦截右侧窗口按钮。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
                onDoubleTap: onToggleMaximize,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: colors.primary.withAlpha(isDark ? 38 : 28),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 17,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '媒体中心',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurface,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _WindowButton(
              tooltip: '最小化',
              icon: Icons.remove_rounded,
              onPressed: windowManager.minimize,
            ),
            _WindowButton(
              tooltip: isMaximized ? '还原' : '最大化',
              icon: isMaximized
                  ? Icons.filter_none_rounded
                  : Icons.crop_square_rounded,
              iconSize: isMaximized ? 14 : 13,
              onPressed: onToggleMaximize,
            ),
            _WindowButton(
              tooltip: '关闭',
              icon: Icons.close_rounded,
              isClose: true,
              onPressed: windowManager.close,
            ),
          ],
        ),
      ),
    );
  }
}

/// 窗口按钮使用矩形轻量悬停反馈，贴近主流 Windows 桌面应用的交互。
class _WindowButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final double iconSize;
  final bool isClose;
  final VoidCallback onPressed;

  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconSize = 16,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hoverColor = widget.isClose
        ? const Color(0xFFC42B1C)
        : colors.onSurface.withAlpha(18);
    final foregroundColor = widget.isClose && _isHovered
        ? Colors.white
        : colors.onSurfaceVariant;

    // 标题栏位于全局 Navigator 外层，避免使用依赖 Overlay 的 Tooltip。
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            width: 46,
            height: double.infinity,
            color: _isHovered ? hoverColor : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: foregroundColor,
            ),
          ),
        ),
      ),
    );
  }
}
