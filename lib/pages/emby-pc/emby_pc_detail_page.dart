import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_person_page.dart';
import 'emby_pc_player_page.dart';
import 'emby_pc_service.dart';
import 'emby_pc_widgets.dart';

class EmbyPcDetailPage extends StatefulWidget {
  final EmbyPcItem item;

  const EmbyPcDetailPage({super.key, required this.item});

  @override
  State<EmbyPcDetailPage> createState() => _EmbyPcDetailPageState();
}

class _EmbyPcDetailPageState extends State<EmbyPcDetailPage> {
  EmbyPcItem? _detail;
  List<EmbyPcItem> _similar = const [];
  bool _loading = true;
  bool _favoriteBusy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final results = await Future.wait<dynamic>([
        EmbyPcService.instance.getItemDetail(widget.item.id),
        EmbyPcService.instance.getSimilarItems(widget.item.id),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as EmbyPcItem;
        _similar = results[1] as List<EmbyPcItem>;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final detail = _detail;
    if (detail == null || _favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    try {
      final value = await EmbyPcService.instance.setFavorite(
        detail.id,
        !detail.isFavorite,
      );
      if (mounted) setState(() => _detail = detail.copyWith(isFavorite: value));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  void _play([int? positionTicks]) {
    final detail = _detail;
    if (detail == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmbyPcPlayerPage(
          item: detail,
          startPositionTicks: positionTicks ?? detail.playbackPositionTicks,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? _DetailError(message: _error, onRetry: _loadDetail)
              : detail == null
                  ? const Center(child: Text('没有可显示的媒体详情'))
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        // 将媒体图片铺满页面作为固定背景，优先展示更适合宽屏的背景图。
                        EmbyPcNetworkImage(
                          url: detail.hasBackdropImage
                              ? EmbyPcService.instance.imageUrl(
                                  detail.id,
                                  type: 'Backdrop',
                                  maxWidth: 1600,
                                )
                              : detail.hasPrimaryImage
                                  ? EmbyPcService.instance.imageUrl(
                                      detail.id,
                                      maxWidth: 1000,
                                    )
                                  : '',
                        ),
                        // 使用主题色渐变压暗图片，保证浅色和深色主题下的正文都清晰可读。
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                colors.surface.withOpacity(0.58),
                                colors.surface.withOpacity(0.86),
                                colors.surface.withOpacity(0.98),
                              ],
                              stops: const [0, 0.48, 1],
                            ),
                          ),
                        ),
                        CustomScrollView(
                          slivers: [
                            SliverAppBar(
                              pinned: true,
                              backgroundColor: colors.surface.withOpacity(0.78),
                              title: Text(detail.name),
                            ),
                            SliverToBoxAdapter(
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 1180),
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: _DetailContent(
                                      detail: detail,
                                      similar: _similar,
                                      favoriteBusy: _favoriteBusy,
                                      onFavorite: _toggleFavorite,
                                      onPlay: _play,
                                      onOpenSimilar: (item) => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => EmbyPcDetailPage(item: item),
                                        ),
                                      ),
                                      onOpenPerson: (person) => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => EmbyPcPersonPage(
                                            personId: person.id,
                                            personName: person.name,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
    );
  }
}

class _DetailContent extends StatelessWidget {
  final EmbyPcItem detail;
  final List<EmbyPcItem> similar;
  final bool favoriteBusy;
  final VoidCallback onFavorite;
  final void Function(int? ticks) onPlay;
  final ValueChanged<EmbyPcItem> onOpenSimilar;
  final ValueChanged<EmbyPcPerson> onOpenPerson;

  const _DetailContent({
    required this.detail,
    required this.similar,
    required this.favoriteBusy,
    required this.onFavorite,
    required this.onPlay,
    required this.onOpenSimilar,
    required this.onOpenPerson,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      // 参考桌面端仅展示演员和导演，避免其它幕后人员挤占横向列表。
      final creditPeople = detail.people
          .where((person) => person.type == 'Actor' || person.type == 'Director')
          .toList();
      final artworkImages = _buildArtworkImages(detail);
      final summary = _Summary(
        detail: detail,
        onFavorite: onFavorite,
        favoriteBusy: favoriteBusy,
        onPlay: onPlay,
      );
      // Primary 竖版海报保留在标题旁，和页面背景使用的 Backdrop 区分展示。
      final poster = SizedBox(
        width: wide ? 230 : 180,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: EmbyPcNetworkImage(
              url: detail.hasPrimaryImage
                  ? EmbyPcService.instance.imageUrl(detail.id, maxWidth: 500)
                  : '',
            ),
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 宽屏时海报位于标题左侧，窄屏时保持原有的上下排列。
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [poster, const SizedBox(width: 28), Expanded(child: summary)],
            )
          else ...[
            Center(child: poster),
            const SizedBox(height: 22),
            summary,
          ],
          if (detail.chapters.isNotEmpty) ...[
            const SizedBox(height: 32),
            const _SectionTitle(
              title: '章节',
              icon: Icons.play_circle_outline_rounded,
            ),
            const SizedBox(height: 12),
            // 使用 Emby 生成的 Chapter 图片展示章节，点击后从对应时间开始播放。
            _ChapterCarousel(
              itemId: detail.id,
              chapters: detail.chapters,
              onPlay: onPlay,
            ),
          ],
          if (artworkImages.isNotEmpty) ...[
            const SizedBox(height: 32),
            _ArtworkSection(images: artworkImages),
          ],
          if (creditPeople.isNotEmpty) ...[
            const SizedBox(height: 32),
            _CastSection(
              people: creditPeople,
              onOpenPerson: onOpenPerson,
            ),
          ],
          if (similar.isNotEmpty) ...[
            const SizedBox(height: 32),
            _SimilarSection(
              items: similar,
              onOpenItem: onOpenSimilar,
            ),
          ],
          const SizedBox(height: 32),
          _OtherInformation(
            detail: detail,
            source: detail.mediaSources.isEmpty
                ? null
                : detail.mediaSources.first,
          ),
          if (detail.mediaSources.isNotEmpty &&
              detail.mediaSources.first.streams.any(
                (stream) => stream.type == 'Video' || stream.type == 'Audio',
              )) ...[
            const SizedBox(height: 32),
            _StreamInformation(source: detail.mediaSources.first),
          ],
        ],
      );
    },
  );
}

// 章节区域保留横向滑动，并在桌面端悬停时显示左右滚动按钮。
class _ChapterCarousel extends StatefulWidget {
  final String itemId;
  final List<EmbyPcChapter> chapters;
  final ValueChanged<int> onPlay;

  const _ChapterCarousel({
    required this.itemId,
    required this.chapters,
    required this.onPlay,
  });

  @override
  State<_ChapterCarousel> createState() => _ChapterCarouselState();
}

class _ChapterCarouselState extends State<_ChapterCarousel> {
  final ScrollController _scrollController = ScrollController();
  bool _hovering = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // 每次滚动约一个可视区域，兼顾章节数量较多时的浏览效率。
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
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 卡片沿用参考页面的 300px 上限，窄屏时收缩到可滑动的 78% 宽度。
        final responsiveWidth = constraints.maxWidth * 0.78;
        final cardWidth = responsiveWidth > 300 ? 300.0 : responsiveWidth;
        final carouselHeight = cardWidth * 9 / 16 + 62;
        return MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: SizedBox(
            height: carouselHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ScrollConfiguration(
                  behavior: const _HorizontalDragScrollBehavior(),
                  child: ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.chapters.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final chapter = widget.chapters[index];
                      return SizedBox(
                        width: cardWidth,
                        child: _ChapterCard(
                          itemId: widget.itemId,
                          chapter: chapter,
                          chapterNumber: index + 1,
                          onPlay: () =>
                              widget.onPlay(chapter.startPositionTicks),
                        ),
                      );
                    },
                  ),
                ),
                if (widget.chapters.length > 1) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: _ChapterNavigationButton(
                        visible: _hovering,
                        icon: Icons.chevron_left_rounded,
                        tooltip: '向左滚动章节',
                        colors: colors,
                        onPressed: () => _scroll(-1),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _ChapterNavigationButton(
                        visible: _hovering,
                        icon: Icons.chevron_right_rounded,
                        tooltip: '向右滚动章节',
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
      },
    );
  }
}

// 导航按钮覆盖在列表两侧，仅在鼠标进入章节区域后响应点击。
class _ChapterNavigationButton extends StatelessWidget {
  final bool visible;
  final IconData icon;
  final String tooltip;
  final ColorScheme colors;
  final VoidCallback onPressed;

  const _ChapterNavigationButton({
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
        color: colors.surface.withOpacity(0.96),
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

// 单个章节卡片提供图片占位、悬停播放浮层以及键盘焦点反馈。
class _ChapterCard extends StatefulWidget {
  final String itemId;
  final EmbyPcChapter chapter;
  final int chapterNumber;
  final VoidCallback onPlay;

  const _ChapterCard({
    required this.itemId,
    required this.chapter,
    required this.chapterNumber,
    required this.onPlay,
  });

  @override
  State<_ChapterCard> createState() => _ChapterCardState();
}

class _ChapterCardState extends State<_ChapterCard> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = _hovering || _focused;
    final name = widget.chapter.name.isEmpty
        ? '章节 ${widget.chapterNumber}'
        : widget.chapter.name;
    final time = _ticksLabel(widget.chapter.startPositionTicks);
    final imageUrl = widget.chapter.imageTag.isEmpty
        ? ''
        : EmbyPcService.instance.imageUrl(
            widget.itemId,
            type: 'Chapter',
            index: widget.chapter.index,
            maxWidth: 640,
          );
    return Tooltip(
      message: '播放$name，从 $time 开始',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(8),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: colors.primary.withOpacity(0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : const [],
        ),
        // 描边放在前景层，避免章节图片覆盖悬停时的主题色边框。
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? colors.primary : colors.outlineVariant,
          ),
        ),
        child: Material(
          color: colors.surface,
          child: InkWell(
            onTap: widget.onPlay,
            onHover: (value) => setState(() => _hovering = value),
            onFocusChange: (value) => setState(() => _focused = value),
            mouseCursor: SystemMouseCursors.click,
            child: Column(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      EmbyPcNetworkImage(url: imageUrl),
                      // 悬停时压暗章节图，确保播放按钮在不同亮度图片上都清晰。
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        color: active
                            ? const Color(0xFF0F172A).withOpacity(0.14)
                            : Colors.transparent,
                      ),
                      Center(
                        child: AnimatedSlide(
                          offset: active ? Offset.zero : const Offset(0, 0.08),
                          duration: const Duration(milliseconds: 180),
                          child: AnimatedOpacity(
                            opacity: active ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F172A).withOpacity(0.7),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.58),
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x520F172A),
                                    blurRadius: 28,
                                    offset: Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 20,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 20 / 14,
                              ),
                        ),
                      ),
                      SizedBox(
                        height: 18,
                        child: Text(
                          time,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 18 / 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 艺术图区域展示 Emby 返回的背景图、截图及其它图片类型。
class _ArtworkSection extends StatelessWidget {
  final List<_DetailImageRef> images;

  const _ArtworkSection({required this.images});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionTitle(
        title: '影片图片与艺术图',
        icon: Icons.image_outlined,
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final responsiveWidth = constraints.maxWidth * 0.78;
          final cardWidth = responsiveWidth > 330 ? 330.0 : responsiveWidth;
          return _DetailHorizontalCarousel(
            itemCount: images.length,
            itemWidth: cardWidth,
            height: cardWidth * 9 / 16 + 46,
            itemBuilder: (context, index) => _ArtworkCard(
              image: images[index],
              onOpen: () => _showArtworkPreview(context, images, index),
            ),
          );
        },
      ),
    ],
  );
}

// 艺术图卡片在悬停或聚焦时使用主题色描边，并保持固定 16:9 布局。
class _ArtworkCard extends StatefulWidget {
  final _DetailImageRef image;
  final VoidCallback onOpen;

  const _ArtworkCard({required this.image, required this.onOpen});

  @override
  State<_ArtworkCard> createState() => _ArtworkCardState();
}

class _ArtworkCardState extends State<_ArtworkCard> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = _hovering || _focused;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        boxShadow: active
            ? [
                BoxShadow(
                  color: colors.primary.withOpacity(0.16),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : const [],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: Material(
        color: colors.surface,
        child: InkWell(
          onTap: widget.onOpen,
          onHover: (value) => setState(() => _hovering = value),
          onFocusChange: (value) => setState(() => _focused = value),
          mouseCursor: SystemMouseCursors.click,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: EmbyPcNetworkImage(url: widget.image.url),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                child: Text(
                  widget.image.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 演职人员沿用参考页面的 3:4 头像卡片，并支持进入人物详情页。
class _CastSection extends StatelessWidget {
  final List<EmbyPcPerson> people;
  final ValueChanged<EmbyPcPerson> onOpenPerson;

  const _CastSection({required this.people, required this.onOpenPerson});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionTitle(
        title: '演员与导演',
        icon: Icons.person_outline_rounded,
      ),
      const SizedBox(height: 12),
      _DetailHorizontalCarousel(
        itemCount: people.length,
        itemWidth: 148,
        height: 264,
        showNavigation: false,
        itemBuilder: (context, index) {
          final person = people[index];
          return _CastCard(
            person: person,
            onOpen: person.id.isEmpty ? null : () => onOpenPerson(person),
          );
        },
      ),
    ],
  );
}

class _CastCard extends StatelessWidget {
  final EmbyPcPerson person;
  final VoidCallback? onOpen;

  const _CastCard({required this.person, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final personType = _personTypeLabel(person);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        mouseCursor: onOpen == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 3 / 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: EmbyPcNetworkImage(
                    url: person.id.isNotEmpty && person.hasPrimaryImage
                        ? EmbyPcService.instance.imageUrl(
                            person.id,
                            maxWidth: 260,
                          )
                        : '',
                  ),
                ),
              ),
              const SizedBox(height: 9),
              Text(
                person.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                personType,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 类似影片继续复用项目现有媒体卡片，并补充桌面端左右导航。
class _SimilarSection extends StatelessWidget {
  final List<EmbyPcItem> items;
  final ValueChanged<EmbyPcItem> onOpenItem;

  const _SimilarSection({required this.items, required this.onOpenItem});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionTitle(
        title: '更多类似',
        icon: Icons.collections_bookmark_outlined,
      ),
      const SizedBox(height: 12),
      _DetailHorizontalCarousel(
        itemCount: items.length,
        itemWidth: 160,
        height: 258,
        spacing: 12,
        itemBuilder: (context, index) => EmbyPcMediaTile(
          item: items[index],
          imageStyle: 'poster',
          onOpen: () => onOpenItem(items[index]),
        ),
      ),
    ],
  );
}

// 图片、人物和类似影片共用横向列表行为，导航按钮只负责滚动当前列表。
class _DetailHorizontalCarousel extends StatefulWidget {
  final int itemCount;
  final double itemWidth;
  final double height;
  final double spacing;
  final bool showNavigation;
  final IndexedWidgetBuilder itemBuilder;

  const _DetailHorizontalCarousel({
    required this.itemCount,
    required this.itemWidth,
    required this.height,
    required this.itemBuilder,
    this.spacing = 16,
    this.showNavigation = true,
  });

  @override
  State<_DetailHorizontalCarousel> createState() =>
      _DetailHorizontalCarouselState();
}

class _DetailHorizontalCarouselState
    extends State<_DetailHorizontalCarousel> {
  final ScrollController _scrollController = ScrollController();
  bool _hovering = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ScrollConfiguration(
              behavior: const _HorizontalDragScrollBehavior(),
              child: ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
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
                  padding: const EdgeInsets.only(left: 10),
                  child: _ChapterNavigationButton(
                    visible: _hovering,
                    icon: Icons.chevron_left_rounded,
                    tooltip: '向左滚动',
                    colors: colors,
                    onPressed: () => _scroll(-1),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _ChapterNavigationButton(
                    visible: _hovering,
                    icon: Icons.chevron_right_rounded,
                    tooltip: '向右滚动',
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

// 其它信息按两列自适应排列，窄屏时自动改为单列。
class _OtherInformation extends StatelessWidget {
  final EmbyPcItem detail;
  final EmbyPcMediaSource? source;

  const _OtherInformation({required this.detail, required this.source});

  @override
  Widget build(BuildContext context) {
    final mediaSource = source;
    final studioNames = detail.studios
        .map((studio) => studio.name)
        .where((name) => name.isNotEmpty)
        .toList();
    final mediaPath = mediaSource != null && mediaSource.path.isNotEmpty
        ? mediaSource.path
        : detail.path;
    final mediaLines = <String>[
      if (mediaPath.isNotEmpty) mediaPath,
      [
        if (mediaSource != null && mediaSource.container.isNotEmpty)
          mediaSource.container.toUpperCase(),
        if (mediaSource != null && mediaSource.size > 0)
          _fileSize(mediaSource.size),
      ].join('  '),
      if (detail.dateCreated.isNotEmpty)
        '添加于 ${_dateTimeLabel(detail.dateCreated)}',
    ].where((line) => line.isNotEmpty).toList();
    final cards = <Widget>[
      if (detail.genres.isNotEmpty)
        _InfoCard(
          title: '流派',
          icon: Icons.movie_filter_outlined,
          lines: [detail.genres.join('，')],
        ),
      if (detail.tags.isNotEmpty)
        _InfoCard(
          title: '标签',
          icon: Icons.sell_outlined,
          lines: [detail.tags.join('，')],
        ),
      if (studioNames.isNotEmpty)
        _InfoCard(
          title: '工作室',
          icon: Icons.business_outlined,
          lines: [studioNames.join('，')],
        ),
      _InfoCard(
        title: '媒体信息',
        icon: Icons.calendar_month_outlined,
        lines: mediaLines.isEmpty ? const ['暂无媒体信息'] : mediaLines,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          title: '其它信息',
          icon: Icons.description_outlined,
        ),
        const SizedBox(height: 12),
        _ResponsiveCardGrid(children: cards),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> lines;

  const _InfoCard({
    required this.title,
    required this.icon,
    required this.lines,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardTitle(title: title, icon: icon),
            ...lines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  line,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 视频和音频流分别生成信息卡片，空字段在生成展示行时统一过滤。
class _StreamInformation extends StatelessWidget {
  final EmbyPcMediaSource source;

  const _StreamInformation({required this.source});

  @override
  Widget build(BuildContext context) {
    final streams = source.streams
        .where((stream) => stream.type == 'Video' || stream.type == 'Audio')
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(
          title: '视频信息',
          icon: Icons.schedule_outlined,
        ),
        const SizedBox(height: 12),
        _ResponsiveCardGrid(
          children: streams
              .map(
                (stream) => _StreamCard(
                  title: stream.type == 'Video' ? '视频' : '音频',
                  icon: stream.type == 'Video'
                      ? Icons.videocam_outlined
                      : Icons.headphones_outlined,
                  rows: _mediaStreamRows(stream),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _StreamCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<_InformationRow> rows;

  const _StreamCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardTitle(title: title, icon: icon),
            const SizedBox(height: 10),
            ...rows.map(
              (row) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        row.label,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        row.value,
                        style: const TextStyle(fontSize: 13, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  final String title;
  final IconData icon;

  const _CardTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );
}

class _ResponsiveCardGrid extends StatelessWidget {
  final List<Widget> children;

  const _ResponsiveCardGrid({required this.children});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final cardWidth = constraints.maxWidth >= 600
          ? (constraints.maxWidth - 14) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: 14,
        runSpacing: 14,
        children: children
            .map((child) => SizedBox(width: cardWidth, child: child))
            .toList(),
      );
    },
  );
}

class _InformationRow {
  final String label;
  final String value;

  const _InformationRow(this.label, this.value);
}

// 仅为详情页横向列表补充鼠标拖动，不改变项目其它滚动区域的行为。
class _HorizontalDragScrollBehavior extends MaterialScrollBehavior {
  const _HorizontalDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

class _DetailImageRef {
  final String label;
  final String url;

  const _DetailImageRef({
    required this.label,
    required this.url,
  });
}

// 图片预览提供缩放、滑动切换、左右按钮和关闭操作，不依赖额外组件库。
class _ArtworkPreviewDialog extends StatefulWidget {
  final List<_DetailImageRef> images;
  final int initialIndex;

  const _ArtworkPreviewDialog({
    required this.images,
    required this.initialIndex,
  });

  @override
  State<_ArtworkPreviewDialog> createState() => _ArtworkPreviewDialogState();
}

class _ArtworkPreviewDialogState extends State<_ArtworkPreviewDialog> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _showPage(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.images[_currentIndex];
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: const Color(0xF20F172A),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.images.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.all(56),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: SizedBox.expand(
                    child: EmbyPcNetworkImage(
                      url: widget.images[index].url,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: IconButton.filled(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ),
            if (_currentIndex > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: IconButton.filled(
                    tooltip: '上一张',
                    onPressed: () => _showPage(_currentIndex - 1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                ),
              ),
            if (_currentIndex < widget.images.length - 1)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: IconButton.filled(
                    tooltip: '下一张',
                    onPressed: () => _showPage(_currentIndex + 1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    '${image.label}  ${_currentIndex + 1}/${widget.images.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final EmbyPcItem detail;
  final bool favoriteBusy;
  final VoidCallback onFavorite;
  final void Function(int? ticks) onPlay;

  const _Summary({
    required this.detail,
    required this.favoriteBusy,
    required this.onFavorite,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      if (detail.productionYear != null) '${detail.productionYear}',
      if (detail.officialRating.isNotEmpty) detail.officialRating,
      if (detail.runtimeLabel.isNotEmpty) detail.runtimeLabel,
      if (detail.communityRating != null)
        '★ ${detail.communityRating!.toStringAsFixed(1)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          detail.name,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(meta.join('  ·  ')),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () => onPlay(null),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(
                detail.playbackPositionTicks > 0 ? '继续播放' : '播放',
              ),
            ),
            OutlinedButton.icon(
              onPressed: favoriteBusy ? null : onFavorite,
              icon: favoriteBusy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      detail.isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                    ),
              label: Text(detail.isFavorite ? '已收藏' : '收藏'),
            ),
          ],
        ),
        if (detail.overview.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(detail.overview, style: const TextStyle(height: 1.65)),
        ],
      ],
    );
  }
}

// 分区标题可按需携带图标，未传入时保持其它详情区块的原有样式。
class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData? icon;

  const _SectionTitle({required this.title, this.icon});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) ...[
        Icon(icon, size: 20),
        const SizedBox(width: 8),
      ],
      Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _DetailError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _DetailError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 48),
        const SizedBox(height: 12),
        Text(message),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}

String _ticksLabel(int ticks) {
  final duration = Duration(microseconds: ticks ~/ 10);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return duration.inHours > 0 ? '${duration.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}

String _fileSize(int size) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}

// 将详情图片标签转换为 Emby 图片地址，海报仍只用于页面顶部展示。
List<_DetailImageRef> _buildArtworkImages(EmbyPcItem detail) {
  final images = <_DetailImageRef>[];

  void addImage(String type, int index, String label) {
    images.add(
      _DetailImageRef(
        label: label,
        url: EmbyPcService.instance.imageUrl(
          detail.id,
          type: type,
          index: index,
          maxWidth: 1280,
        ),
      ),
    );
  }

  for (var index = 0; index < detail.backdropImageTags.length; index++) {
    addImage('Backdrop', index, '影片图片 ${index + 1}');
  }
  for (var index = 0; index < detail.screenshotImageTags.length; index++) {
    addImage('Screenshot', index, '艺术图 ${index + 1}');
  }
  const extraImages = <String, String>{
    'Art': '艺术图',
    'Thumb': '缩略图',
    'Banner': '横幅',
    'Logo': 'Logo',
    'Disc': '碟片',
  };
  for (final image in extraImages.entries) {
    final imageTag = detail.imageTags[image.key]?.toString() ?? '';
    if (imageTag.isNotEmpty) {
      addImage(image.key, 0, image.value);
    }
  }
  return images;
}

void _showArtworkPreview(
  BuildContext context,
  List<_DetailImageRef> images,
  int initialIndex,
) {
  showDialog<void>(
    context: context,
    builder: (_) => _ArtworkPreviewDialog(
      images: images,
      initialIndex: initialIndex,
    ),
  );
}

String _personTypeLabel(EmbyPcPerson person) {
  if (person.type == 'Director') return '导演';
  if (person.type == 'Actor') return person.role.isEmpty ? '演员' : person.role;
  if (person.role.isNotEmpty) return person.role;
  return person.type.isEmpty ? '演职人员' : person.type;
}

String _dateTimeLabel(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final date = parsed.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${date.year}/${twoDigits(date.month)}/${twoDigits(date.day)} '
      '${twoDigits(date.hour)}:${twoDigits(date.minute)}';
}

// 根据流类型生成信息行，接口未返回的空字段不会占据卡片空间。
List<_InformationRow> _mediaStreamRows(EmbyPcMediaStream stream) {
  final rows = <_InformationRow>[];

  void add(String label, String value) {
    if (value.isNotEmpty) rows.add(_InformationRow(label, value));
  }

  add('标题', stream.title);
  if (stream.type == 'Video') {
    add('编解码器', stream.codec);
    add('编解码器标签', stream.codecTag);
    add('用户配置', stream.profile);
    add('等级', stream.level?.toString() ?? '');
    add(
      '分辨率',
      stream.width != null && stream.height != null
          ? '${stream.width}x${stream.height}'
          : '',
    );
    add('长宽比', stream.aspectRatio);
    add('交错', _booleanLabel(stream.isInterlaced));
    add(
      '帧率',
      _numberLabel(stream.averageFrameRate ?? stream.realFrameRate),
    );
    add('比特率', _bitrateLabel(stream.bitrate));
    add('基色', stream.colorPrimaries);
    add('色域', stream.colorSpace);
    add('色彩转换', stream.colorTransfer);
    add('位深度', stream.bitDepth == null ? '' : '${stream.bitDepth} bit');
    add('像素格式', stream.pixelFormat);
    add('参考帧', stream.refFrames?.toString() ?? '');
  } else {
    add('语言', stream.language);
    add('编解码器', stream.codec);
    add('编解码器标签', stream.codecTag);
    add('用户配置', stream.profile);
    add('布局', stream.channelLayout);
    add('频道', stream.channels == null ? '' : '${stream.channels} ch');
    add('比特率', _bitrateLabel(stream.bitrate));
    add('采样率', stream.sampleRate == null ? '' : '${stream.sampleRate} Hz');
    add('默认', _booleanLabel(stream.isDefault));
  }
  return rows;
}

String _numberLabel(double? value) {
  if (value == null) return '';
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(
          RegExp(r'\.$'),
          '',
        );
}

String _bitrateLabel(int? bitrate) {
  if (bitrate == null || bitrate <= 0) return '';
  if (bitrate >= 1000000) return '${(bitrate / 1000000).round()} mbps';
  if (bitrate >= 1000) return '${(bitrate / 1000).round()} kbps';
  return '$bitrate bps';
}

String _booleanLabel(bool? value) {
  if (value == null) return '';
  return value ? '是' : '否';
}
