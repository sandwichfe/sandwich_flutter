part of 'emby_pc_detail_page.dart';

// 章节横向列表及其交互组件。
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
                          onPlay:
                              () => widget.onPlay(chapter.startPositionTicks),
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
    final name =
        widget.chapter.name.isEmpty
            ? '章节 ${widget.chapterNumber}'
            : widget.chapter.name;
    final time = _ticksLabel(widget.chapter.startPositionTicks);
    final imageUrl =
        widget.chapter.imageTag.isEmpty
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
          boxShadow:
              active
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
                        color:
                            active
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
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
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
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
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
