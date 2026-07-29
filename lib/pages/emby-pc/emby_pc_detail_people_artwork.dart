part of 'emby_pc_detail_page.dart';

// 图片、演职人员和相似影片等可横向浏览的详情区块。
class _ArtworkSection extends StatelessWidget {
  final List<_DetailImageRef> images;

  const _ArtworkSection({required this.images});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionTitle(title: '影片图片与艺术图', icon: Icons.image_outlined),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final responsiveWidth = constraints.maxWidth * 0.78;
          final cardWidth = responsiveWidth > 330 ? 330.0 : responsiveWidth;
          return EmbyPcHorizontalCarousel(
            itemCount: images.length,
            itemWidth: cardWidth,
            height: cardWidth * 9 / 16 + 46,
            navigationLabel: '艺术图',
            itemBuilder:
                (context, index) => _ArtworkCard(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
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
      const _SectionTitle(title: '演员与导演', icon: Icons.person_outline_rounded),
      const SizedBox(height: 12),
      EmbyPcHorizontalCarousel(
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
        mouseCursor:
            onOpen == null
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
                    url:
                        person.id.isNotEmpty && person.hasPrimaryImage
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
      EmbyPcHorizontalCarousel(
        itemCount: items.length,
        itemWidth: 160,
        height: 258,
        spacing: 12,
        navigationLabel: '类似影片',
        itemBuilder:
            (context, index) => EmbyPcMediaTile(
              item: items[index],
              imageStyle: 'poster',
              onOpen: () => onOpenItem(items[index]),
            ),
      ),
    ],
  );
}

// 其它信息按两列自适应排列，窄屏时自动改为单列。
