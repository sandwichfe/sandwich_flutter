part of 'emby_pc_detail_page.dart';

// 分片影片：同一部影片被切成 `_1` / `_2` 多个文件时，在图片区块下方列出同组的全部部分。
// 卡片样式与「影片图片与艺术图」保持一致，只是额外带序号徽标与时长。
class _PartsSection extends StatelessWidget {
  final String currentItemId;
  final List<EmbyPcItem> parts;
  final ValueChanged<EmbyPcItem> onOpenItem;

  const _PartsSection({
    required this.currentItemId,
    required this.parts,
    required this.onOpenItem,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SectionTitle(
        title: '本片共 ${parts.length} 部分',
        icon: Icons.video_library_outlined,
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final responsiveWidth = constraints.maxWidth * 0.78;
          final cardWidth = responsiveWidth > 330 ? 330.0 : responsiveWidth;
          return EmbyPcHorizontalCarousel(
            itemCount: parts.length,
            itemWidth: cardWidth,
            height: cardWidth * 9 / 16 + 46,
            navigationLabel: '分片',
            itemBuilder:
                (context, index) => _PartCard(
                  part: parts[index],
                  // 缺号时按组内排序位置展示，避免出现 `1/3`、`3/3` 这种断号。
                  position: index + 1,
                  total: parts.length,
                  current: parts[index].id == currentItemId,
                  onOpen:
                      parts[index].id == currentItemId
                          ? null
                          : () => onOpenItem(parts[index]),
                ),
          );
        },
      ),
    ],
  );
}

// 分片卡片与图片卡片同构：16:9 缩略图 + 单行说明，当前项用主题色描边且不可点击。
class _PartCard extends StatefulWidget {
  final EmbyPcItem part;
  final int position;
  final int total;
  final bool current;
  final VoidCallback? onOpen;

  const _PartCard({
    required this.part,
    required this.position,
    required this.total,
    required this.current,
    required this.onOpen,
  });

  @override
  State<_PartCard> createState() => _PartCardState();
}

class _PartCardState extends State<_PartCard> {
  bool _hovering = false;
  bool _focused = false;

  String _imageUrl() {
    final part = widget.part;
    if (part.hasBackdropImage) {
      return EmbyPcService.instance.imageUrlForItem(
        part,
        type: 'Backdrop',
        maxWidth: 640,
      );
    }
    if (part.hasPrimaryImage) {
      return EmbyPcService.instance.imageUrlForItem(part, maxWidth: 640);
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = (_hovering || _focused) && !widget.current;
    final part = widget.part;
    final duration = part.runTimeTicks > 0 ? _ticksLabel(part.runTimeTicks) : '';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        boxShadow:
            active
                ? [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: 0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
                : const [],
      ),
      // 描边放在前景层，避免缩略图覆盖当前项与悬停时的主题色边框。
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              widget.current || active
                  ? colors.primary
                  : colors.outlineVariant,
        ),
      ),
      child: Material(
        color: colors.surface,
        child: InkWell(
          onTap: widget.onOpen,
          onHover: (value) => setState(() => _hovering = value),
          onFocusChange: (value) => setState(() => _focused = value),
          mouseCursor:
              widget.current
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    EmbyPcNetworkImage(url: _imageUrl()),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _PartBadge(
                        label: '${widget.position}/${widget.total}',
                        colors: colors,
                        highlighted: false,
                      ),
                    ),
                    if (widget.current)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: _PartBadge(
                          label: '当前',
                          colors: colors,
                          highlighted: true,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        part.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (duration.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        duration,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 序号徽标压在缩略图上：深色底保证亮暗画面上都能读清，"当前"用主题色区分。
class _PartBadge extends StatelessWidget {
  final String label;
  final ColorScheme colors;
  final bool highlighted;

  const _PartBadge({
    required this.label,
    required this.colors,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: highlighted ? colors.primary : const Color(0xCC0F172A),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        label,
        style: TextStyle(
          color: highlighted ? colors.onPrimary : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
