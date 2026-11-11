import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../widgets/windows_title_bar.dart';
import 'emby_pc_models.dart';
import 'emby_pc_service.dart';
import 'emby_pc_theme.dart';

// Emby PC 横向内容统一使用左右按钮翻页，同时保留鼠标拖动和触控滑动。
class EmbyPcHorizontalCarousel extends StatefulWidget {
  final int itemCount;
  final double itemWidth;
  final double height;
  final double spacing;
  final bool showNavigation;
  final String navigationLabel;
  final EdgeInsetsGeometry padding;
  final IndexedWidgetBuilder itemBuilder;

  const EmbyPcHorizontalCarousel({
    super.key,
    required this.itemCount,
    required this.itemWidth,
    required this.height,
    required this.itemBuilder,
    this.spacing = 16,
    this.showNavigation = true,
    this.navigationLabel = '',
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
  });

  @override
  State<EmbyPcHorizontalCarousel> createState() =>
      _EmbyPcHorizontalCarouselState();
}

class _EmbyPcHorizontalCarouselState extends State<EmbyPcHorizontalCarousel> {
  final _scrollController = ScrollController();
  bool _hovering = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // 每次切换约一个可视区域，较窄窗口仍保证有明确的翻页距离。
  void _scroll(int direction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final viewportDistance = position.viewportDimension * 0.72;
    final distance = viewportDistance < 280 ? 280.0 : viewportDistance;
    final target = (_scrollController.offset + direction * distance)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final labelSuffix = widget.navigationLabel.isEmpty
        ? ''
        : widget.navigationLabel;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ScrollConfiguration(
              behavior: const _EmbyPcHorizontalDragScrollBehavior(),
              child: ListView.separated(
                controller: _scrollController,
                padding: widget.padding,
                scrollDirection: Axis.horizontal,
                itemCount: widget.itemCount,
                separatorBuilder: (_, _) => SizedBox(width: widget.spacing),
                itemBuilder: (context, index) => SizedBox(
                  width: widget.itemWidth,
                  child: widget.itemBuilder(context, index),
                ),
              ),
            ),
            if (widget.showNavigation && widget.itemCount > 1) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _EmbyPcCarouselNavigationButton(
                    visible: _hovering,
                    icon: Icons.chevron_left_rounded,
                    tooltip: '向左滚动$labelSuffix',
                    onPressed: () => _scroll(-1),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _EmbyPcCarouselNavigationButton(
                    visible: _hovering,
                    icon: Icons.chevron_right_rounded,
                    tooltip: '向右滚动$labelSuffix',
                    onPressed: () => _scroll(1),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// 导航按钮仅在鼠标进入当前横向区域后显示，避免遮挡卡片内容。
class _EmbyPcCarouselNavigationButton extends StatelessWidget {
  final bool visible;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _EmbyPcCarouselNavigationButton({
    required this.visible,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: Tooltip(
        message: tooltip,
        child: Material(
          // 半透明黑底玻璃圆钮，悬浮在封面上时不会破坏画面。
          color: Colors.black.withValues(alpha: 0.55),
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          shape: CircleBorder(
            side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 40,
              child: Icon(icon, size: 24, color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  );
}

// 公共横向列表只补充鼠标拖动，不接管鼠标滚轮事件。
class _EmbyPcHorizontalDragScrollBehavior extends MaterialScrollBehavior {
  const _EmbyPcHorizontalDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

// 长列表回到顶部：滚动超过阈值后右下角浮现按钮，所有列表页统一用这一个组件。
// 通过 builder 交出滚动控制器，页面无需自己维护滚动状态；已经持有控制器的列表
// （例如需要跨视图记住滚动位置）传入 controller 即可复用同一份滚动状态。
class EmbyPcScrollToTop extends StatefulWidget {
  final ScrollController? controller;
  final Widget Function(BuildContext context, ScrollController controller)
  builder;
  // 默认滚动约一屏多一点才出现，避免轻微滚动就弹出按钮。
  final double threshold;
  final EdgeInsetsGeometry padding;
  final String tooltip;

  const EmbyPcScrollToTop({
    super.key,
    required this.builder,
    this.controller,
    this.threshold = 420,
    this.padding = const EdgeInsets.only(right: 24, bottom: 24),
    this.tooltip = '回到顶部',
  });

  @override
  State<EmbyPcScrollToTop> createState() => _EmbyPcScrollToTopState();
}

class _EmbyPcScrollToTopState extends State<EmbyPcScrollToTop> {
  // 只有调用方没有提供控制器时才由组件自己持有并负责销毁。
  ScrollController? _inner;
  bool _visible = false;

  ScrollController get _controller => widget.controller ?? _inner!;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant EmbyPcScrollToTop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _unbind(oldWidget.controller);
    _visible = false;
    _bind();
  }

  @override
  void dispose() {
    _unbind(widget.controller);
    super.dispose();
  }

  void _bind() {
    if (widget.controller == null) _inner = ScrollController();
    _controller.addListener(_handleScrollChanged);
  }

  void _unbind(ScrollController? controller) {
    (controller ?? _inner)?.removeListener(_handleScrollChanged);
    // 外部控制器由页面负责销毁，这里只回收自建的实例。
    if (controller == null) {
      _inner?.dispose();
      _inner = null;
    }
  }

  // 只在可见状态真正变化时重建，滚动过程本身不触发整页刷新。
  void _handleScrollChanged() {
    if (!mounted || !_controller.hasClients) return;
    final visible = _controller.offset > widget.threshold;
    if (visible == _visible) return;
    setState(() => _visible = visible);
  }

  void _scrollToTop() {
    if (!_controller.hasClients) return;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final target = _controller.position.minScrollExtent;
    if (reduceMotion) {
      _controller.jumpTo(target);
      return;
    }
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.builder(context, _controller),
        Positioned.fill(
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: widget.padding,
              child: IgnorePointer(
                ignoring: !_visible,
                child: AnimatedSlide(
                  offset: _visible ? Offset.zero : const Offset(0, 0.4),
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _visible ? 1 : 0,
                    duration: duration,
                    child: Material(
                      color: skin.surface.withValues(alpha: 0.9),
                      elevation: 10,
                      shadowColor: Colors.black.withValues(alpha: 0.4),
                      shape: CircleBorder(
                        side: BorderSide(color: skin.tint(0.35)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _scrollToTop,
                        child: SizedBox.square(
                          dimension: 44,
                          child: Icon(
                            Icons.vertical_align_top_rounded,
                            size: 21,
                            color: skin.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// 卡片只负责分发管理动作，具体弹窗和接口调用由所在页面处理。
// togglePlayed 用于手动标记已看/未看，属于用户数据而不是元数据编辑。
enum EmbyPcMediaAction {
  editMetadata,
  editImages,
  refreshMetadata,
  togglePlayed,
  // 仅人物页使用：从 TMDB 刮削该演员的资料与图片。
  scrapePerson,
}

// 卡片右键菜单的动作项：包含播放/收藏这类入口，无法直接复用 EmbyPcMediaAction。
enum _CardMenuAction {
  play,
  favorite,
  togglePlayed,
  editMetadata,
  editImages,
  refreshMetadata,
}

class EmbyPcMediaTile extends StatefulWidget {
  final EmbyPcItem item;
  final String imageStyle;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;
  final VoidCallback? onFavorite;
  final ValueChanged<EmbyPcMediaAction>? onAction;
  final bool favoriteBusy;
  final bool actionBusy;

  // 指定后替换默认媒体元数据，用于播放记录等具有专属摘要的列表。
  final String secondaryLabel;
  // 人物列表出生日期缺失时不应回退显示通用类型文本。
  final bool hideDefaultMetadata;
  // 横向推荐位把标题压进图片底部，观感更接近视频平台的海报流。
  final bool overlayCaption;
  // 触屏设备没有悬停，操作按钮需要常显，否则收藏/更多完全点不到。
  final bool alwaysShowActions;

  const EmbyPcMediaTile({
    super.key,
    required this.item,
    required this.imageStyle,
    required this.onOpen,
    this.onPlay,
    this.onFavorite,
    this.onAction,
    this.favoriteBusy = false,
    this.actionBusy = false,
    this.secondaryLabel = '',
    this.hideDefaultMetadata = false,
    this.overlayCaption = false,
    this.alwaysShowActions = false,
  });

  @override
  State<EmbyPcMediaTile> createState() => _EmbyPcMediaTileState();
}

class _EmbyPcMediaTileState extends State<EmbyPcMediaTile> {
  bool _hovered = false;
  bool _focused = false;
  // 卡片自身持有焦点节点：方向键切换焦点、回车打开都由 InkWell 承担。
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focused == _focusNode.hasFocus) return;
    setState(() => _focused = _focusNode.hasFocus);
  }

  // 悬停、键盘聚焦或触屏常显都视作"操作区可见"。
  bool get _revealed =>
      _hovered || _focused || widget.alwaysShowActions;

  @override
  Widget build(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final backdrop = widget.imageStyle == 'backdrop';
    final hasImage = backdrop
        ? widget.item.hasBackdropImage
        : widget.item.hasPrimaryImage;
    // 带上条目图片标签，服务端换图后 URL 变化，客户端缓存才会失效。
    final imageUrl = EmbyPcService.instance.imageUrlForItem(
      widget.item,
      type: backdrop ? 'Backdrop' : 'Primary',
      maxWidth: backdrop ? 720 : 420,
    );
    final progress = widget.item.runTimeTicks <= 0
        ? 0.0
        : (widget.item.playbackPositionTicks / widget.item.runTimeTicks)
              .clamp(0.0, 1.0)
              .toDouble();
    // 网格里每张卡片独立成层，滚动时避免整屏重新绘制。
    return RepaintBoundary(
      child: Semantics(
        button: true,
        label: '打开 ${widget.item.name}',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              // 阴影只在悬停/聚焦时绘制：整屏几十张卡片常驻模糊阴影会拖慢滚动。
              boxShadow: _hovered || _focused
                  ? [
                      BoxShadow(
                        color: skin.tint(skin.dark ? 0.24 : 0.16),
                        blurRadius: 26,
                        offset: const Offset(0, 12),
                      ),
                    ]
                  : const [],
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: widget.onOpen,
                      focusNode: _focusNode,
                      hoverColor: Colors.transparent,
                      // 桌面右键菜单：播放、收藏与条目维护，避免每次都先开详情页。
                      onSecondaryTapDown: (details) =>
                          _showCardMenu(details.globalPosition),
                      child: widget.overlayCaption
                          ? _buildOverlayCard(
                              context,
                              imageUrl: hasImage ? imageUrl : '',
                            )
                          : _buildStandardCard(
                              context,
                              imageUrl: hasImage ? imageUrl : '',
                              progress: progress,
                            ),
                    ),
                  ),
                ),
                // 背景图卡的封面就是整张卡，进度条只能落在卡片底边；
                // 放在 Material 裁剪层之上，两端才不会又被圆角重新收成圆弧。
                if (widget.overlayCaption && progress > 0)
                  Positioned(
                    // 左右内缩与圆角半径一致，进度条两端正好落在圆角起点的竖直切线上。
                    left: 14,
                    right: 14,
                    bottom: 0,
                    height: embyPcProgressHeight,
                    child: _PlaybackProgress(value: progress, color: skin.accent),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 图片内嵌标题的横向卡片：整块是封面，底部用渐变压住文字；
  // 进度条由 build 叠在卡片底边上（封面本身铺满整卡，不留空带）。
  Widget _buildOverlayCard(BuildContext context, {required String imageUrl}) {
    return _buildOverlayArtwork(context, imageUrl);
  }

  // 封面本体：图片 + 压暗层 + 内嵌标题和悬浮操作，占满进度条槽位以上的空间。
  Widget _buildOverlayArtwork(BuildContext context, String imageUrl) {
    final skin = EmbyPcSkin.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        EmbyPcNetworkImage(
          url: imageUrl,
          fallbackIcon: embyPcFallbackIcon(widget.item.type),
          fallbackLabel: embyPcFallbackLabel(widget.item.type),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          color: _hovered
              ? Colors.black.withValues(alpha: 0.20)
              : Colors.transparent,
        ),
        // 底部压暗与媒体库卡片保持一致：冷调深色 + 多段缓入，浅色占位底上不出现硬分界。
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x0010141A),
                Color(0x0D10141A),
                Color(0x2610141A),
                Color(0x5C10141A),
                Color(0xA610141A),
              ],
              stops: [0.36, 0.50, 0.65, 0.82, 1],
            ),
          ),
        ),
        if (_qualityLabel(widget.item).isNotEmpty)
          Positioned(
            top: 9,
            right: 9,
            child: _MediaBadge(label: _qualityLabel(widget.item)),
          ),
        if (widget.item.played)
          Positioned(top: 9, left: 9, child: const _MediaBadge(label: '已看')),
        Positioned(
          left: 14,
          // 右下角常驻收藏/更多按钮，文字区为它让出固定宽度。
          right: 92,
          bottom: 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Microsoft YaHei UI',
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
                ),
              ),
              const SizedBox(height: 3),
              _buildOverlayMeta(context),
            ],
          ),
        ),
        if (widget.onPlay != null)
          Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _revealed ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_revealed,
                child: _CircleAction(
                  icon: Icons.play_arrow_rounded,
                  size: 52,
                  iconSize: 28,
                  tooltip: '播放',
                  onPressed: widget.onPlay!,
                  accent: skin.accent,
                ),
              ),
            ),
          ),
        if (widget.onFavorite != null || widget.onAction != null)
          Positioned(
            right: 12,
            bottom: 12,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _revealed ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_revealed,
                child: _buildCardActionRow(context, compact: true),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOverlayMeta(BuildContext context) {
    final secondary = widget.secondaryLabel;
    final plain = <String>[
      if (widget.item.productionYear != null) '${widget.item.productionYear}',
      if (widget.item.runtimeLabel.isNotEmpty) widget.item.runtimeLabel,
    ];
    final text = secondary.isNotEmpty
        ? secondary
        : (plain.isEmpty ? widget.item.type : plain.join(' · '));
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.item.communityRating != null) ...[
          const Icon(Icons.star_rounded, size: 13, color: Color(0xFFF5B942)),
          const SizedBox(width: 2),
          Text(
            widget.item.communityRating!.toStringAsFixed(1),
            style: const TextStyle(
              color: Color(0xFFF5C563),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 11.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStandardCard(
    BuildContext context, {
    required String imageUrl,
    required double progress,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _buildImageFrame(
            context,
            imageUrl: imageUrl,
            progress: progress,
          ),
        ),
        _buildTileCaption(context),
      ],
    );
  }

  // 只让图片区域承担边框和阴影，文字直接落在画布上，列表会更轻、更接近桌面媒体库。
  Widget _buildImageFrame(
    BuildContext context, {
    required String imageUrl,
    required double progress,
  }) {
    final skin = EmbyPcSkin.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _hovered ? skin.tint(0.6) : skin.hairline),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: _buildPosterArtwork(context, imageUrl),
            ),
          ),
          // 画在圆角裁剪之上，两端保持直角；左右内缩 11 与图片框圆角一致，
          // 端点正好落在圆角起点的竖直切线上，不会压到弧线。
          if (progress > 0)
            Positioned(
              left: 11,
              right: 11,
              bottom: 0,
              height: embyPcProgressHeight,
              child: _PlaybackProgress(value: progress, color: skin.accent),
            ),
        ],
      ),
    );
  }

  // 封面本体：图片 + 悬停压暗 + 角标与悬浮操作。
  Widget _buildPosterArtwork(BuildContext context, String imageUrl) {
    return Stack(
      fit: StackFit.expand,
      children: [
        EmbyPcNetworkImage(
          url: imageUrl,
          fallbackIcon: embyPcFallbackIcon(widget.item.type),
          fallbackLabel: embyPcFallbackLabel(widget.item.type),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: _hovered ? 0.12 : 0),
                Colors.black.withValues(alpha: _hovered ? 0.34 : 0.10),
              ],
            ),
          ),
        ),
        if (_qualityLabel(widget.item).isNotEmpty)
          Positioned(
            top: 9,
            right: 9,
            child: _MediaBadge(label: _qualityLabel(widget.item)),
          ),
        // 已看状态常驻左上角，和右上角的分辨率角标互不遮挡。
        if (widget.item.played)
          Positioned(
            top: 9,
            left: 9,
            child: const _MediaBadge(label: '已看'),
          ),
        _buildCardActions(bottom: 8),
      ],
    );
  }

  Widget _buildTileCaption(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: TextStyle(
              fontFamily: 'Microsoft YaHei UI',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _hovered ? skin.accent : skin.scheme.onSurface,
            ),
            child: Text(
              widget.item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          if (widget.secondaryLabel.isEmpty && !widget.hideDefaultMetadata)
            _MediaMetadata(item: widget.item)
          else
            Text(
              widget.secondaryLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: skin.textSecondary, fontSize: 11.5),
            ),
        ],
      ),
    );
  }

  Widget _buildCardActions({required double bottom}) => Stack(
    children: [
      if (widget.onPlay != null)
        Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _revealed ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_revealed,
              child: _CircleAction(
                icon: Icons.play_arrow_rounded,
                size: 50,
                iconSize: 27,
                tooltip: '播放',
                onPressed: widget.onPlay,
              ),
            ),
          ),
        ),
      if (widget.onFavorite != null || widget.onAction != null)
        Positioned(
          right: 10,
          bottom: bottom,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            // 收藏状态只改变图标样式，不影响卡片操作按钮的悬浮显隐。
            opacity: _revealed ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_revealed,
              child: _buildCardActionRow(context),
            ),
          ),
        ),
    ],
  );

  Widget _buildCardActionRow(BuildContext context, {bool compact = false}) {
    final size = compact ? 34.0 : 36.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onFavorite != null)
          _CircleAction(
            icon: widget.item.isFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            size: size,
            iconSize: 18,
            tooltip: widget.item.isFavorite ? '取消收藏' : '收藏',
            // 收藏态用暖红色，和视频平台的“追剧”标记一致。
            accent: widget.item.isFavorite
                ? const Color(0xFFFF5C7A)
                : Colors.white,
            busy: widget.favoriteBusy,
            onPressed: widget.favoriteBusy ? null : widget.onFavorite,
          ),
        if (widget.onFavorite != null && widget.onAction != null)
          const SizedBox(width: 8),
        if (widget.onAction != null)
          PopupMenuButton<EmbyPcMediaAction>(
            tooltip: '更多',
            padding: EdgeInsets.zero,
            enabled: !widget.actionBusy,
            onSelected: widget.onAction,
            itemBuilder: (context) => [
              // 已看状态就地切换，成功后列表角标与进度条同步更新。
              PopupMenuItem(
                value: EmbyPcMediaAction.togglePlayed,
                child: Row(
                  children: [
                    Icon(
                      widget.item.played
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(widget.item.played ? '标记为未看' : '标记为已看'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: EmbyPcMediaAction.editMetadata,
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('编辑元数据'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: EmbyPcMediaAction.editImages,
                child: Row(
                  children: [
                    Icon(Icons.image_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('编辑图像'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: EmbyPcMediaAction.refreshMetadata,
                child: Row(
                  children: [
                    Icon(Icons.refresh_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('刷新元数据'),
                  ],
                ),
              ),
            ],
            child: _GlassCircle(
              size: size,
              child: widget.actionBusy
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.more_horiz_rounded,
                      size: 21,
                      color: Colors.white,
                    ),
            ),
          ),
      ],
    );
  }

  // 右键菜单：桌面端常用操作不必先进详情页，也和卡片上的悬浮按钮保持一致。
  Future<void> _showCardMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final action = await showMenu<_CardMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.onPlay != null)
          _buildMenuItem(_CardMenuAction.play, Icons.play_arrow_rounded, '播放'),
        if (widget.onFavorite != null)
          _buildMenuItem(
            _CardMenuAction.favorite,
            widget.item.isFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            widget.item.isFavorite ? '取消收藏' : '收藏',
          ),
        if (widget.onAction != null) ...[
          const PopupMenuDivider(),
          _buildMenuItem(
            _CardMenuAction.togglePlayed,
            widget.item.played
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            widget.item.played ? '标记为未看' : '标记为已看',
          ),
          _buildMenuItem(_CardMenuAction.editMetadata, Icons.edit_outlined, '编辑元数据'),
          _buildMenuItem(_CardMenuAction.editImages, Icons.image_outlined, '编辑图像'),
          _buildMenuItem(
            _CardMenuAction.refreshMetadata,
            Icons.refresh_outlined,
            '刷新元数据',
          ),
        ],
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _CardMenuAction.play:
        widget.onPlay?.call();
      case _CardMenuAction.favorite:
        widget.onFavorite?.call();
      case _CardMenuAction.togglePlayed:
        widget.onAction?.call(EmbyPcMediaAction.togglePlayed);
      case _CardMenuAction.editMetadata:
        widget.onAction?.call(EmbyPcMediaAction.editMetadata);
      case _CardMenuAction.editImages:
        widget.onAction?.call(EmbyPcMediaAction.editImages);
      case _CardMenuAction.refreshMetadata:
        widget.onAction?.call(EmbyPcMediaAction.refreshMetadata);
    }
  }

  PopupMenuItem<_CardMenuAction> _buildMenuItem(
    _CardMenuAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: value,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    ),
  );

  String _qualityLabel(EmbyPcItem item) {
    final width = item.width ?? 0;
    final height = item.height ?? 0;
    if (width >= 3800 || height >= 2000) return '4K';
    if (width >= 1900 || height >= 1000) return '1080';
    if (width >= 1200 || height >= 700) return '720';
    return '';
  }
}

// 观看历史行：左侧 16:9 缩略图带续播进度，右侧标题与最近播放摘要，
// 比海报网格更贴近「最近在看」的清单感，也让一行里的信息密度更高。
class EmbyPcWatchHistoryRow extends StatefulWidget {
  final EmbyPcItem item;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  const EmbyPcWatchHistoryRow({
    super.key,
    required this.item,
    required this.onOpen,
    this.onPlay,
  });

  @override
  State<EmbyPcWatchHistoryRow> createState() => _EmbyPcWatchHistoryRowState();
}

class _EmbyPcWatchHistoryRowState extends State<EmbyPcWatchHistoryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final progress = widget.item.runTimeTicks <= 0
        ? 0.0
        : (widget.item.playbackPositionTicks / widget.item.runTimeTicks)
              .clamp(0.0, 1.0)
              .toDouble();
    return RepaintBoundary(
      child: Semantics(
        button: true,
        label: '打开 ${widget.item.name}',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.click,
          child: _buildRowContainer(
            context,
            child: Row(
              children: [
                _buildThumbnail(context, progress),
                const SizedBox(width: 14),
                Expanded(child: _buildSummary(context, progress)),
                if (widget.onPlay != null) ...[
                  const SizedBox(width: 10),
                  _buildPlayButton(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 悬停时整行浮起淡色底，未悬停保持透明，列表看起来像干净的清单。
  Widget _buildRowContainer(
    BuildContext context, {
    required Widget child,
  }) {
    final skin = EmbyPcSkin.of(context);
    return Material(
      color: _hovered ? skin.tint(skin.dark ? 0.12 : 0.06) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onOpen,
        hoverColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: child,
        ),
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context, double progress) {
    final item = widget.item;
    // 影视条目优先用背景图，取不到时退回竖版主图，避免整行出现空白占位。
    final useBackdrop = item.hasBackdropImage;
    final hasImage = useBackdrop ? item.hasBackdropImage : item.hasPrimaryImage;
    final imageUrl = hasImage
        ? EmbyPcService.instance.imageUrlForItem(
            item,
            type: useBackdrop ? 'Backdrop' : 'Primary',
            maxWidth: 480,
          )
        : '';
    return SizedBox(
      width: 132,
      height: 74,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  EmbyPcNetworkImage(
                    url: imageUrl,
                    fallbackIcon: embyPcFallbackIcon(item.type),
                    fallbackLabel: embyPcFallbackLabel(item.type),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    color: Colors.black.withValues(
                      alpha: _hovered ? 0.22 : 0.04,
                    ),
                  ),
                  if (item.runtimeLabel.isNotEmpty)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _MediaBadge(label: item.runtimeLabel),
                    ),
                ],
              ),
            ),
          ),
          // 与封面卡一致：进度条压在圆角裁剪之上，两端保持直角，
          // 左右内缩 8 与缩略图圆角一致，端点不压到弧线。
          if (progress > 0)
            Positioned(
              left: 8,
              right: 8,
              bottom: 0,
              height: embyPcProgressHeight,
              child: _PlaybackProgress(
                value: progress,
                color: EmbyPcSkin.of(context).accent,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummary(BuildContext context, double progress) {
    final skin = EmbyPcSkin.of(context);
    final item = widget.item;
    final percent = (progress * 100).round();
    final meta = <String>[
      _historyTimeLabel(item.lastPlayedDate),
      if (item.productionYear != null) '${item.productionYear}',
      if (item.played)
        '已看完'
      else if (percent > 0)
        '已看 $percent%',
    ].where((value) => value.isNotEmpty).join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          style: TextStyle(
            fontFamily: 'Microsoft YaHei UI',
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: _hovered ? skin.accent : skin.scheme.onSurface,
          ),
          child: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (item.communityRating != null) ...[
              const Icon(Icons.star_rounded, size: 14, color: Color(0xFFF3B33D)),
              const SizedBox(width: 2),
              Text(
                item.communityRating!.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: skin.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: skin.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlayButton(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final played = widget.item.played;
    return Tooltip(
      message: played ? '重新播放' : '继续播放',
      child: IconButton(
        onPressed: widget.onPlay,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(38),
          padding: EdgeInsets.zero,
          backgroundColor: _hovered
              ? skin.tint(0.16)
              : skin.surfaceAlt.withValues(alpha: skin.dark ? 0.55 : 1),
          foregroundColor: _hovered ? skin.accent : skin.textSecondary,
          side: BorderSide(color: _hovered ? skin.tint(0.5) : skin.hairline),
          shape: const CircleBorder(),
        ),
        icon: const Icon(Icons.play_arrow_rounded, size: 21),
      ),
    );
  }
}

// 观看历史摘要里的时间用相对表述更直观：当天/昨天给时刻，更早按天或日期显示。
String _historyTimeLabel(String isoDate) {
  final parsed = DateTime.tryParse(isoDate);
  if (parsed == null) return '';
  final local = parsed.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final playedDay = DateTime(local.year, local.month, local.day);
  final days = today.difference(playedDay).inDays;
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final clock = '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  if (days <= 0) return '今天 $clock';
  if (days == 1) return '昨天 $clock';
  if (days < 7) return '$days 天前';
  if (local.year == now.year) return '${local.month} 月 ${local.day} 日';
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
}

class _MediaMetadata extends StatelessWidget {
  final EmbyPcItem item;
  final bool onDark;

  const _MediaMetadata({required this.item, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final muted = onDark
        ? Colors.white.withValues(alpha: 0.74)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final plain = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.runtimeLabel.isNotEmpty) item.runtimeLabel,
    ];
    return Row(
      children: [
        if (item.communityRating != null) ...[
          const Icon(Icons.star_rounded, size: 14, color: Color(0xFFF3B33D)),
          const SizedBox(width: 2),
          Text(
            item.communityRating!.toStringAsFixed(1),
            style: TextStyle(color: muted, fontSize: 12),
          ),
          if (plain.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text('·', style: TextStyle(color: muted, fontSize: 12)),
            const SizedBox(width: 6),
          ],
        ],
        Flexible(
          child: Text(
            plain.isEmpty
                ? (item.type.isEmpty ? '媒体' : item.type)
                : plain.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// 进度条厚度：叠在封面底边上，不参与卡片布局，所以有进度和无进度时卡片高度一致。
const double embyPcProgressHeight = 4;

// 进度条：两端按卡片圆角半径内缩，保持直角，看起来和圆角的小边平行；
// 因为压在封面上，轨道用半透明深色兜底，亮图和浅色占位底上都能看清剩余部分。
class _PlaybackProgress extends StatelessWidget {
  final double value;
  final Color color;

  const _PlaybackProgress({required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ColoredBox(color: Color(0x6610141A)),
      FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value.clamp(0.0, 1.0),
        child: ColoredBox(color: color),
      ),
    ],
  );
}

// 无封面占位的类型图标：按条目类型换图形，比统一的影片图标更易辨认。
IconData embyPcFallbackIcon(String type) => switch (type) {
  'Series' || 'Season' || 'Episode' => Icons.live_tv_outlined,
  'BoxSet' => Icons.collections_bookmark_outlined,
  'Person' => Icons.person_outline_rounded,
  'MusicAlbum' || 'Audio' || 'MusicVideo' => Icons.music_note_rounded,
  'Photo' || 'PhotoAlbum' => Icons.photo_outlined,
  _ => Icons.movie_outlined,
};

// 无封面占位的类型文案，与图标成对出现，尺寸过小的地方会自动隐藏。
String embyPcFallbackLabel(String type) => switch (type) {
  'Movie' => '电影',
  'Series' || 'Season' || 'Episode' => '剧集',
  'BoxSet' => '合集',
  'Person' => '人物',
  'MusicAlbum' || 'Audio' || 'MusicVideo' => '音乐',
  'Photo' || 'PhotoAlbum' => '照片',
  _ => '媒体',
};

class EmbyPcNetworkImage extends StatelessWidget {
  final String url;
  final BoxFit fit;

  // 无封面时使用的类型图标与低饱和标签，卡片场景传入可让占位更有辨识度。
  final IconData? fallbackIcon;
  final String? fallbackLabel;

  const EmbyPcNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.fallbackIcon,
    this.fallbackLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (url.isEmpty) {
      return _ImagePlaceholder(
        color: colors.surfaceContainerHigh,
        icon: fallbackIcon,
        label: fallbackLabel,
      );
    }
    // 按实际显示宽度解码：列表卡片不必把 1600px 原图整张放进内存缓存。
    return LayoutBuilder(
      builder: (context, constraints) {
        final memWidth = constraints.hasBoundedWidth
            ? ((constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(64, 2048))
                  .toInt()
            : null;
        return CachedNetworkImage(
          imageUrl: url,
          // 缓存键去掉 api_key：换令牌或重装后同一张海报仍命中已有缓存。
          cacheKey: EmbyPcService.imageCacheKey(url),
          memCacheWidth: memWidth,
          fit: fit,
          fadeInDuration: const Duration(milliseconds: 160),
          placeholder: (_, _) => _ImagePlaceholder(
            color: colors.surfaceContainerHigh,
            loading: true,
          ),
          errorWidget: (_, _, _) => _ImagePlaceholder(
            color: colors.surfaceContainerHigh,
            icon: fallbackIcon,
            label: fallbackLabel,
          ),
        );
      },
    );
  }
}

// 无封面占位：固定使用浅色海报底，与深色画布形成克制的对比，文字/图标统一压低饱和度。
class _ImagePlaceholder extends StatelessWidget {
  final Color color;
  final bool loading;
  final IconData? icon;
  final String? label;

  const _ImagePlaceholder({
    required this.color,
    this.loading = false,
    this.icon,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    // 图片加载期间使用低对比度呼吸骨架，避免列表中同时出现多个转圈动画。
    if (loading) return _ImageLoadingSkeleton(color: color);
    final text = label ?? '';
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : 240.0;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 180.0;
        final shortest = width < height ? width : height;
        // 小缩略图只留图标，文字在空间不足时隐藏，避免被压成一团。
        final showLabel = text.isNotEmpty && shortest >= 118 && height >= 96;
        final badgeSize = (shortest * 0.42).clamp(26.0, 60.0);
        final iconSize = (badgeSize * 0.5).clamp(12.0, 28.0);
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFAFBFC), Color(0xFFE6EAF0)],
            ),
          ),
          child: Stack(
            children: [
              // 左上角白色柔光让浅色底不至于是一块死板的灰板。
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(-0.55, -0.9),
                      radius: 1.15,
                      colors: [Color(0xB3FFFFFF), Color(0x00FFFFFF)],
                    ),
                  ),
                ),
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: badgeSize,
                      height: badgeSize,
                      decoration: BoxDecoration(
                        // 浅底上用半透明白色徽标 + 极淡描边，避免图标区域糊成一片。
                        color: Colors.white.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(badgeSize * 0.32),
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                      child: Icon(
                        icon ?? Icons.movie_outlined,
                        size: iconSize,
                        color: Colors.black.withValues(alpha: 0.34),
                      ),
                    ),
                    if (showLabel) ...[
                      SizedBox(height: badgeSize * 0.22),
                      Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.1,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withValues(alpha: 0.34),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ImageLoadingSkeleton extends StatefulWidget {
  final Color color;

  const _ImageLoadingSkeleton({required this.color});

  @override
  State<_ImageLoadingSkeleton> createState() => _ImageLoadingSkeletonState();
}

class _ImageLoadingSkeletonState extends State<_ImageLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 缓慢往返改变骨架明暗，保持加载反馈柔和且不过度抢眼。
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final highlightColor = Color.alphaBlend(
      colors.onSurface.withOpacity(0.06),
      widget.color,
    );
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ColoredBox(
        color: Color.lerp(
          widget.color,
          highlightColor,
          Curves.easeInOut.transform(_controller.value),
        )!,
      ),
    );
  }
}

class _MediaBadge extends StatelessWidget {
  final String label;

  const _MediaBadge({required this.label});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          height: 1.1,
        ),
      ),
    ),
  );
}

// 封面上的玻璃圆钮：半透明黑底 + 极细白边，深色浅色封面都能压住。
class _GlassCircle extends StatelessWidget {
  final double size;
  final Widget child;

  const _GlassCircle({required this.size, required this.child});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Center(child: child),
    ),
  );
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? accent;
  final bool busy;

  const _CircleAction({
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.tooltip,
    required this.onPressed,
    this.accent,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = busy
        ? SizedBox.square(
            dimension: iconSize * 0.78,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Icon(icon, size: iconSize, color: accent ?? Colors.white);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: _GlassCircle(size: size, child: content),
        ),
      ),
    );
  }
}

// 加载占位符：在分页加载时显示骨架屏，提供更流畅的视觉反馈
class EmbyPcLoadingPlaceholder extends StatelessWidget {
  final bool isBackdrop;

  const EmbyPcLoadingPlaceholder({super.key, required this.isBackdrop});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: _ImageLoadingSkeleton(color: colors.surfaceContainerHigh),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 9, 2, 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 14,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 12,
                width: 100,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// 页头统一高度：工作台、详情/人物页顶栏与侧栏品牌区共用同一数值，
// 切换页面时内容区不会上下跳动。
class EmbyPcHeaderMetrics {
  const EmbyPcHeaderMetrics._();

  static const double height = 64;
}

// 桌面页头外壳：统一背景、底部分割线、窗口拖动区与窗口按钮，
// 页头只需提供内容，窗口按钮高度自动跟随页头高度。
class EmbyPcTopBarShell extends StatelessWidget {
  final Widget child;
  final Color color;
  final Color hairline;
  final double height;
  final bool showWindowButtons;
  // 深色页头（如播放器）可以覆盖窗口按钮配色。
  final Color? captionForegroundColor;
  final Color? captionHoverColor;

  const EmbyPcTopBarShell({
    super.key,
    required this.child,
    required this.color,
    required this.hairline,
    this.height = EmbyPcHeaderMetrics.height,
    this.showWindowButtons = false,
    this.captionForegroundColor,
    this.captionHoverColor,
  });

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        Expanded(child: child),
        if (showWindowButtons) ...[
          // 窗口按钮占满整个页头高度，悬停背景才不会被上下留白切断。
          Container(width: 1, height: 24, color: hairline),
          WindowsCaptionButtons(
            height: height,
            foregroundColor: captionForegroundColor,
            hoverColor: captionHoverColor,
          ),
        ],
      ],
    );
    return Material(
      color: color,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: hairline)),
        ),
        child: showWindowButtons
            // 空白处可拖动窗口；按钮和输入框位于上层，优先响应鼠标事件。
            ? Stack(
                children: [
                  Positioned.fill(
                    child: WindowsDragArea(child: const SizedBox.expand()),
                  ),
                  Positioned.fill(child: content),
                ],
              )
            : content,
      ),
    );
  }
}
