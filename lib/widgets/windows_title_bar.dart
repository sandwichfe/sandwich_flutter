import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 桌面端的全局窗口框架，提供精简标题栏和原生窗口操作。
class WindowsTitleBar extends StatefulWidget {
  final Widget child;

  const WindowsTitleBar({super.key, required this.child});

  /// 页面自带窗口按钮（例如工作台页头）时置为 true，全局标题栏让出高度，
  /// 避免顶部出现两条重复的窗口控制栏。
  static final ValueNotifier<bool> embedded = ValueNotifier<bool>(false);

  /// 由切换全屏的调用方直接告知目标状态：标题栏与窗口尺寸会在同一帧内变化，
  /// 避免"先缩窗口再收起标题栏"造成的二次布局闪烁。
  static void setFullscreen(bool value) {
    _WindowsTitleBarState._instance?._applyFullscreen(value);
  }

  @override
  State<WindowsTitleBar> createState() => _WindowsTitleBarState();
}

class _WindowsTitleBarState extends State<WindowsTitleBar> with WindowListener {
  static _WindowsTitleBarState? _instance;

  bool _isMaximized = false;
  bool _isFullScreen = false;

  @override
  void initState() {
    super.initState();
    _instance = this;
    windowManager.addListener(this);
    _syncWindowState();
  }

  @override
  void dispose() {
    if (identical(_instance, this)) _instance = null;
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 同步窗口初始状态，避免热重载或恢复窗口后图标显示不准确。
  Future<void> _syncWindowState() async {
    final isMaximized = await windowManager.isMaximized();
    final isFullScreen = await windowManager.isFullScreen();
    if (!mounted) return;
    // 状态没变时不重建，避免全屏切换期间多出一次无意义的布局。
    if (_isMaximized == isMaximized && _isFullScreen == isFullScreen) return;
    setState(() {
      _isMaximized = isMaximized;
      _isFullScreen = isFullScreen;
    });
  }

  void _applyFullscreen(bool value) {
    if (!mounted || _isFullScreen == value) return;
    setState(() => _isFullScreen = value);
  }

  /// 以原生窗口状态为准刷新标题栏，并在窗口完成异步状态迁移后再校正一次。
  void _scheduleSync() {
    if (!mounted) return;
    unawaited(_syncWindowState());
    // 退出全屏依赖 PostMessage(SC_MAXIMIZE)，WM_SIZE 处理完后状态才稳定。
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 120), _syncWindowState),
    );
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

  // 事件只作为触发时机，状态一律回查原生窗口，避免 media_kit/window_manager
  // 状态机不同步时把标题栏留在错误状态。
  @override
  void onWindowMaximize() {
    _scheduleSync();
  }

  @override
  void onWindowUnmaximize() {
    _scheduleSync();
  }

  @override
  void onWindowRestore() {
    _scheduleSync();
  }

  @override
  void onWindowEnterFullScreen() {
    _scheduleSync();
  }

  @override
  void onWindowLeaveFullScreen() {
    _scheduleSync();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 标题栏使用中间表面层，下方页面画布和媒体卡片仍保留各自层级。
    final titleBarColor = colors.surfaceContainerLow;

    return ValueListenableBuilder<bool>(
      valueListenable: WindowsTitleBar.embedded,
      builder: (context, embedded, _) {
        return ColoredBox(
          color: colors.surfaceContainerLowest,
          child: Column(
            children: [
              // 页面内嵌窗口按钮时不再绘制全局标题栏，但全屏状态仍优先隐藏。
              if (!_isFullScreen && !embedded)
                _TitleBar(
                  color: titleBarColor,
                  onToggleMaximize: _toggleMaximize,
                ),
              Expanded(child: widget.child),
            ],
          ),
        );
      },
    );
  }
}

class _TitleBar extends StatelessWidget {
  final Color color;
  final VoidCallback onToggleMaximize;

  const _TitleBar({required this.color, required this.onToggleMaximize});

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
                          'Sandwich Player',
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
            const WindowsCaptionButtons(),
          ],
        ),
      ),
    );
  }
}

/// 独立的最小化/最大化/关闭按钮组，供全局标题栏与页面内嵌页头复用。
class WindowsCaptionButtons extends StatefulWidget {
  final double height;
  // 深色页面（如播放器）可以显式指定浅色图标与悬停底色。
  final Color? foregroundColor;
  final Color? hoverColor;

  const WindowsCaptionButtons({
    super.key,
    this.height = 44,
    this.foregroundColor,
    this.hoverColor,
  });

  @override
  State<WindowsCaptionButtons> createState() => _WindowsCaptionButtonsState();
}

class _WindowsCaptionButtonsState extends State<WindowsCaptionButtons>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncState() async {
    final isMaximized = await windowManager.isMaximized();
    if (!mounted || _isMaximized == isMaximized) return;
    setState(() => _isMaximized = isMaximized);
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _syncState();
  }

  // 最大化/还原由系统异步完成，稍后再回查一次，避免图标与窗口状态不一致。
  void _scheduleSync() {
    if (!mounted) return;
    unawaited(_syncState());
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 120), _syncState),
    );
  }

  @override
  void onWindowMaximize() => _scheduleSync();

  @override
  void onWindowUnmaximize() => _scheduleSync();

  @override
  void onWindowRestore() => _scheduleSync();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          tooltip: '最小化',
          icon: Icons.remove_rounded,
          foregroundColor: widget.foregroundColor,
          hoverColor: widget.hoverColor,
          onPressed: windowManager.minimize,
        ),
        _WindowButton(
          tooltip: _isMaximized ? '还原' : '最大化',
          icon: _isMaximized
              ? Icons.filter_none_rounded
              : Icons.crop_square_rounded,
          iconSize: _isMaximized ? 14 : 13,
          foregroundColor: widget.foregroundColor,
          hoverColor: widget.hoverColor,
          onPressed: _toggleMaximize,
        ),
        _WindowButton(
          tooltip: '关闭',
          icon: Icons.close_rounded,
          isClose: true,
          foregroundColor: widget.foregroundColor,
          hoverColor: widget.hoverColor,
          onPressed: windowManager.close,
        ),
      ],
    ),
  );
}

/// 页头空白处的窗口拖动区：按住移动窗口，双击切换最大化。
class WindowsDragArea extends StatelessWidget {
  final Widget child;

  const WindowsDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => unawaited(windowManager.startDragging()),
    onDoubleTap: () async {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    },
    child: child,
  );
}

/// 窗口按钮使用矩形轻量悬停反馈，贴近主流 Windows 桌面应用的交互。
class _WindowButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final double iconSize;
  final bool isClose;
  final Color? foregroundColor;
  final Color? hoverColor;
  final VoidCallback onPressed;

  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconSize = 16,
    this.isClose = false,
    this.foregroundColor,
    this.hoverColor,
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
        : (widget.hoverColor ?? colors.onSurface.withAlpha(18));
    final foregroundColor = widget.isClose && _isHovered
        ? Colors.white
        : (widget.foregroundColor ?? colors.onSurfaceVariant);

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
