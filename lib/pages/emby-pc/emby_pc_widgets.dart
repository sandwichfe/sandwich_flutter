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
  });

  @override
  State<EmbyPcMediaTile> createState() => _EmbyPcMediaTileState();
}

class _EmbyPcMediaTileState extends State<EmbyPcMediaTile> {
  bool _hovered = false;

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
              boxShadow: [
                BoxShadow(
                  color: _hovered
                      ? skin.tint(skin.dark ? 0.24 : 0.16)
                      : Colors.black.withValues(alpha: skin.dark ? 0.30 : 0.07),
                  blurRadius: _hovered ? 26 : 12,
                  offset: Offset(0, _hovered ? 12 : 5),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onOpen,
                hoverColor: Colors.transparent,
                child: widget.overlayCaption
                    ? _buildOverlayCard(
                        context,
                        imageUrl: hasImage ? imageUrl : '',
                        progress: progress,
                      )
                    : _buildStandardCard(
                        context,
                        imageUrl: hasImage ? imageUrl : '',
                        progress: progress,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 图片内嵌标题的横向卡片：整块是封面，底部用渐变压住文字。
  Widget _buildOverlayCard(
    BuildContext context, {
    required String imageUrl,
    required double progress,
  }) {
    final skin = EmbyPcSkin.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        EmbyPcNetworkImage(url: imageUrl),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          color: _hovered
              ? Colors.black.withValues(alpha: 0.20)
              : Colors.transparent,
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0x33000000), Color(0xE6000000)],
              stops: [0.34, 0.60, 1],
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
          bottom: progress > 0 ? 13 : 12,
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
              opacity: _hovered ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_hovered,
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
              opacity: _hovered ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_hovered,
                child: _buildCardActionRow(context, compact: true),
              ),
            ),
          ),
        if (progress > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _PlaybackProgress(value: progress, color: skin.accent),
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Stack(
          fit: StackFit.expand,
          children: [
            EmbyPcNetworkImage(url: imageUrl),
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
            _buildCardActions(bottom: progress > 0 ? 10 : 8),
            if (progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _PlaybackProgress(value: progress, color: skin.accent),
              ),
          ],
        ),
      ),
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
            opacity: _hovered ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_hovered,
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
            opacity: _hovered ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_hovered,
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

  String _qualityLabel(EmbyPcItem item) {
    final width = item.width ?? 0;
    final height = item.height ?? 0;
    if (width >= 3800 || height >= 2000) return '4K';
    if (width >= 1900 || height >= 1000) return '1080';
    if (width >= 1200 || height >= 700) return '720';
    return '';
  }
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

class _PlaybackProgress extends StatelessWidget {
  final double value;
  final Color color;

  const _PlaybackProgress({required this.value, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 3,
    child: LinearProgressIndicator(
      value: value,
      minHeight: 3,
      color: color,
      backgroundColor: Colors.white.withValues(alpha: 0.28),
    ),
  );
}

class EmbyPcNetworkImage extends StatelessWidget {
  final String url;
  final BoxFit fit;

  const EmbyPcNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (url.isEmpty) {
      return _ImagePlaceholder(color: colors.surfaceContainerHigh);
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
          errorWidget: (_, _, _) =>
              _ImagePlaceholder(color: colors.surfaceContainerHigh),
        );
      },
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  final Color color;
  final bool loading;

  const _ImagePlaceholder({required this.color, this.loading = false});

  @override
  Widget build(BuildContext context) {
    // 图片加载期间使用低对比度呼吸骨架，避免列表中同时出现多个转圈动画。
    if (loading) return _ImageLoadingSkeleton(color: color);
    return ColoredBox(
      color: color,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
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
