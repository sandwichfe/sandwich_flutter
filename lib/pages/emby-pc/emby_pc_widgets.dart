import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';

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

class _EmbyPcHorizontalCarouselState
    extends State<EmbyPcHorizontalCarousel> {
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
    final target =
        (_scrollController.offset + direction * distance)
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
    final colors = Theme.of(context).colorScheme;
    final labelSuffix =
        widget.navigationLabel.isEmpty ? '' : widget.navigationLabel;
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
                itemBuilder:
                    (context, index) => SizedBox(
                      width: widget.itemWidth,
                      child: widget.itemBuilder(context, index),
                    ),
              ),
            ),
            if (widget.showNavigation && widget.itemCount > 1) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: _EmbyPcCarouselNavigationButton(
                    visible: _hovering,
                    icon: Icons.chevron_left_rounded,
                    tooltip: '向左滚动$labelSuffix',
                    colors: colors,
                    onPressed: () => _scroll(-1),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _EmbyPcCarouselNavigationButton(
                    visible: _hovering,
                    icon: Icons.chevron_right_rounded,
                    tooltip: '向右滚动$labelSuffix',
                    colors: colors,
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
  final ColorScheme colors;
  final VoidCallback onPressed;

  const _EmbyPcCarouselNavigationButton({
    required this.visible,
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: Material(
        color: colors.surface.withValues(alpha: 0.96),
        elevation: 6,
        shape: CircleBorder(side: BorderSide(color: colors.outlineVariant)),
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon),
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

class EmbyPcMediaTile extends StatefulWidget {
  final EmbyPcItem item;
  final String imageStyle;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;
  final VoidCallback? onFavorite;
  final bool favoriteBusy;

  // 指定后替换默认媒体元数据，用于播放记录等具有专属摘要的列表。
  final String secondaryLabel;

  const EmbyPcMediaTile({
    super.key,
    required this.item,
    required this.imageStyle,
    required this.onOpen,
    this.onPlay,
    this.onFavorite,
    this.favoriteBusy = false,
    this.secondaryLabel = '',
  });

  @override
  State<EmbyPcMediaTile> createState() => _EmbyPcMediaTileState();
}

class _EmbyPcMediaTileState extends State<EmbyPcMediaTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final backdrop = widget.imageStyle == 'backdrop';
    final hasImage =
        backdrop ? widget.item.hasBackdropImage : widget.item.hasPrimaryImage;
    final imageUrl = EmbyPcService.instance.imageUrl(
      widget.item.id,
      type: backdrop ? 'Backdrop' : 'Primary',
      maxWidth: backdrop ? 720 : 420,
    );
    final progress =
        widget.item.runTimeTicks <= 0
            ? 0.0
            : (widget.item.playbackPositionTicks / widget.item.runTimeTicks)
                .clamp(0.0, 1.0)
                .toDouble();
    return Semantics(
      button: true,
      label: '打开 ${widget.item.name}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen,
            hoverColor: Colors.transparent,
            child:
                backdrop
                    ? _buildBackdropCard(
                      context,
                      imageUrl: hasImage ? imageUrl : '',
                      progress: progress,
                    )
                    : _buildPosterCard(
                      context,
                      imageUrl: hasImage ? imageUrl : '',
                      progress: progress,
                    ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackdropCard(
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

  Widget _buildPosterCard(
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
    final colors = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color:
              _hovered
                  ? colors.primary.withValues(alpha: 0.72)
                  : colors.outlineVariant.withValues(alpha: 0.78),
        ),
        boxShadow:
            _hovered
                ? [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.15),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
                : const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          fit: StackFit.expand,
          children: [
            EmbyPcNetworkImage(url: imageUrl),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              color:
                  _hovered
                      ? Colors.black.withValues(alpha: 0.28)
                      : Colors.transparent,
            ),
            if (_qualityLabel(widget.item).isNotEmpty)
              Positioned(
                top: 8,
                right: 8,
                child: _MediaBadge(label: _qualityLabel(widget.item)),
              ),
            _buildCardActions(bottom: progress > 0 ? 8 : 6),
            if (progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _PlaybackProgress(
                  value: progress,
                  color: colors.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTileCaption(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 9, 2, 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: (Theme.of(context).textTheme.titleMedium ??
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))
                .copyWith(color: _hovered ? colors.primary : colors.onSurface),
            child: Text(
              widget.item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          if (widget.secondaryLabel.isEmpty)
            _MediaMetadata(item: widget.item)
          else
            Text(
              widget.secondaryLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
              ),
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
              child: IconButton.filled(
                tooltip: '播放',
                onPressed: widget.onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            ),
          ),
        ),
      if (widget.onFavorite != null)
        Positioned(
          right: 8,
          bottom: bottom,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity:
                (_hovered || widget.item.isFavorite || widget.favoriteBusy)
                    ? 1
                    : 0,
            child: IgnorePointer(
              ignoring: !_hovered && !widget.item.isFavorite,
              child: IconButton.filledTonal(
                tooltip: widget.item.isFavorite ? '取消收藏' : '收藏',
                onPressed: widget.favoriteBusy ? null : widget.onFavorite,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.62),
                  foregroundColor:
                      widget.item.isFavorite
                          ? const Color(0xFFE84C5B)
                          : Colors.white,
                ),
                icon:
                    widget.favoriteBusy
                        ? const SizedBox.square(
                          dimension: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : Icon(
                          widget.item.isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 19,
                        ),
              ),
            ),
          ),
        ),
    ],
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

/// 列表主视觉只使用当前媒体的真实 Backdrop，不引入与内容无关的装饰图片。
class EmbyPcFeatureBanner extends StatelessWidget {
  final EmbyPcItem item;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

  const EmbyPcFeatureBanner({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final imageUrl = EmbyPcService.instance.imageUrl(
      item.id,
      type: 'Backdrop',
      maxWidth: 1280,
    );
    final isResumable = item.playbackPositionTicks > 0 && !item.played;
    return Semantics(
      button: true,
      label: '打开 ${item.name}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 220,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  EmbyPcNetworkImage(url: imageUrl),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [Color(0xF0000000), Color(0x18000000)],
                        stops: [0.0, 0.78],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 22, 28, 22),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isResumable ? '继续观看' : '精选媒体',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.78),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 25,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 7),
                            _MediaMetadata(item: item, onDark: true),
                            if (item.overview.trim().isNotEmpty) ...[
                              const SizedBox(height: 9),
                              Text(
                                item.overview.trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.82),
                                  fontSize: 13,
                                  height: 1.45,
                                ),
                              ),
                            ],
                            const SizedBox(height: 13),
                            FilledButton.icon(
                              onPressed: onPlay,
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: colors.primary,
                                minimumSize: const Size(0, 38),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(isResumable ? '继续播放' : '播放'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaMetadata extends StatelessWidget {
  final EmbyPcItem item;
  final bool onDark;

  const _MediaMetadata({required this.item, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final muted =
        onDark
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
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 160),
      placeholder:
          (_, _) => _ImagePlaceholder(
            color: colors.surfaceContainerHigh,
            loading: true,
          ),
      errorWidget:
          (_, _, _) => _ImagePlaceholder(color: colors.surfaceContainerHigh),
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
      builder:
          (context, child) => ColoredBox(
            color:
                Color.lerp(
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
      color: Colors.black.withOpacity(0.68),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    ),
  );
}
