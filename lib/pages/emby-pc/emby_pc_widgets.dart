import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';

class EmbyPcMediaTile extends StatefulWidget {
  final EmbyPcItem item;
  final String imageStyle;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;
  final VoidCallback? onFavorite;
  final bool favoriteBusy;

  const EmbyPcMediaTile({
    super.key,
    required this.item,
    required this.imageStyle,
    required this.onOpen,
    this.onPlay,
    this.onFavorite,
    this.favoriteBusy = false,
  });

  @override
  State<EmbyPcMediaTile> createState() => _EmbyPcMediaTileState();
}

class _EmbyPcMediaTileState extends State<EmbyPcMediaTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final backdrop = widget.imageStyle == 'backdrop';
    final hasImage = backdrop
        ? widget.item.hasBackdropImage
        : widget.item.hasPrimaryImage;
    final imageUrl = EmbyPcService.instance.imageUrl(
      widget.item.id,
      type: backdrop ? 'Backdrop' : 'Primary',
      maxWidth: backdrop ? 720 : 420,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        // 媒体卡片底色跟随背景色，主题色只用于操作按钮和选中状态。
        color: colors.surface,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    EmbyPcNetworkImage(
                      url: hasImage ? imageUrl : '',
                      fit: BoxFit.cover,
                    ),
                    if (_hovered || widget.favoriteBusy)
                      ColoredBox(
                        color: Colors.black.withOpacity(0.46),
                        child: Stack(
                          children: [
                            if (widget.onPlay != null)
                              Center(
                                child: IconButton.filled(
                                  tooltip: '播放',
                                  onPressed: widget.onPlay,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                ),
                              ),
                            if (widget.onFavorite != null)
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: IconButton.filledTonal(
                                  tooltip: widget.item.isFavorite ? '取消收藏' : '收藏',
                                  onPressed:
                                      widget.favoriteBusy ? null : widget.onFavorite,
                                  icon: widget.favoriteBusy
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Icon(
                                          widget.item.isFavorite
                                              ? Icons.favorite_rounded
                                              : Icons.favorite_border_rounded,
                                        ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (_qualityLabel(widget.item).isNotEmpty)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _MediaBadge(label: _qualityLabel(widget.item)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _secondaryText(widget.item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _secondaryText(EmbyPcItem item) {
    final values = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.communityRating != null)
        '★ ${item.communityRating!.toStringAsFixed(1)}',
      if (item.runtimeLabel.isNotEmpty) item.runtimeLabel,
    ];
    return values.isEmpty ? (item.type.isEmpty ? '媒体' : item.type) : values.join(' · ');
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
    if (url.isEmpty) return _ImagePlaceholder(color: colors.surface);
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 160),
      placeholder: (_, _) => _ImagePlaceholder(
        color: colors.surface,
        loading: true,
      ),
      errorWidget: (_, _, _) =>
          _ImagePlaceholder(color: colors.surface),
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
