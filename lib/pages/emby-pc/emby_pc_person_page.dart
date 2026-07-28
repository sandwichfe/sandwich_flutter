import 'package:flutter/material.dart';

import 'emby_pc_detail_page.dart';
import 'emby_pc_models.dart';
import 'emby_pc_service.dart';
import 'emby_pc_widgets.dart';

class EmbyPcPersonPage extends StatefulWidget {
  final String personId;
  final String personName;

  const EmbyPcPersonPage({
    super.key,
    required this.personId,
    required this.personName,
  });

  @override
  State<EmbyPcPersonPage> createState() => _EmbyPcPersonPageState();
}

class _EmbyPcPersonPageState extends State<EmbyPcPersonPage> {
  EmbyPcItem? _person;
  List<EmbyPcItem> _items = const [];
  bool _loading = true;
  bool _favoriteBusy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadPerson();
  }

  Future<void> _loadPerson() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final results = await Future.wait<dynamic>([
        EmbyPcService.instance.getPersonDetail(widget.personId),
        EmbyPcService.instance.getPersonItems(widget.personId),
      ]);
      if (!mounted) return;
      setState(() {
        _person = results[0] as EmbyPcItem;
        _items = (results[1] as EmbyPcPage).items;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // 人物收藏与影片收藏使用相同的 Emby FavoriteItems 接口。
  Future<void> _toggleFavorite() async {
    final person = _person;
    if (person == null || _favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    try {
      final value = await EmbyPcService.instance.setFavorite(
        person.id,
        !person.isFavorite,
      );
      if (mounted) setState(() => _person = person.copyWith(isFavorite: value));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    final colors = Theme.of(context).colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final contentDuration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 220);
    final title =
        person?.name.isNotEmpty == true ? person!.name : widget.personName;

    final Widget pageContent;
    if (_loading) {
      pageContent = const Center(
        key: ValueKey('person-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (_error.isNotEmpty) {
      pageContent = KeyedSubtree(
        key: const ValueKey('person-error'),
        child: _PersonError(message: _error, onRetry: _loadPerson),
      );
    } else if (person == null) {
      pageContent = const Center(
        key: ValueKey('person-empty'),
        child: Text('没有可显示的人物资料'),
      );
    } else {
      pageContent = CustomScrollView(
        key: ValueKey('person-${person.id}'),
        slivers: [
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _PersonContent(
                    person: person,
                    items: _items,
                    favoriteBusy: _favoriteBusy,
                    onFavorite: _toggleFavorite,
                    onOpenItem:
                        (item) => Navigator.of(context).push(
                          embyPcFadeRoute(
                            context,
                            (_) => EmbyPcDetailPage(item: item),
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

    return Scaffold(
      backgroundColor: colors.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 人物图片仅作为低对比度背景渐显，顶部导航和正文不会随请求整体替换。
          _PersonBackdrop(
            person: person,
            duration:
                reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 260),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  colors.surface.withValues(alpha: 0.72),
                  colors.surface.withValues(alpha: 0.92),
                  colors.surface.withValues(alpha: 0.99),
                ],
                stops: const [0, 0.42, 1],
              ),
            ),
          ),
          Column(
            children: [
              EmbyPcImmersiveTopBar(title: title, loading: _loading),
              Expanded(
                child: AnimatedSwitcher(
                  duration: contentDuration,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: pageContent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PersonBackdrop extends StatelessWidget {
  final EmbyPcItem? person;
  final Duration duration;

  const _PersonBackdrop({required this.person, required this.duration});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currentPerson = person;
    final url =
        currentPerson?.hasPrimaryImage == true
            ? EmbyPcService.instance.imageUrl(currentPerson!.id, maxWidth: 1200)
            : '';
    return ExcludeSemantics(
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child:
            url.isEmpty
                ? ColoredBox(
                  key: const ValueKey('person-backdrop-empty'),
                  color: colors.surfaceContainerLowest,
                )
                : SizedBox.expand(
                  key: ValueKey(url),
                  child: EmbyPcNetworkImage(url: url),
                ),
      ),
    );
  }
}

class _PersonContent extends StatelessWidget {
  final EmbyPcItem person;
  final List<EmbyPcItem> items;
  final bool favoriteBusy;
  final VoidCallback onFavorite;
  final ValueChanged<EmbyPcItem> onOpenItem;

  const _PersonContent({
    required this.person,
    required this.items,
    required this.favoriteBusy,
    required this.onFavorite,
    required this.onOpenItem,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final useWideHero = constraints.maxWidth >= 680;
      // 宽屏使用参考页面的大头像，窄屏缩小头像以避免摘要文字溢出。
      final posterWidth =
          useWideHero
              ? 268.0
              : constraints.maxWidth < 180
              ? constraints.maxWidth
              : 180.0;
      final poster = SizedBox(
        width: posterWidth,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withOpacity(0.12),
                  blurRadius: 34,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: EmbyPcNetworkImage(
                url:
                    person.hasPrimaryImage
                        ? EmbyPcService.instance.imageUrl(
                          person.id,
                          maxWidth: 520,
                        )
                        : '',
              ),
            ),
          ),
        ),
      );
      final facts = _personFacts(person);
      final biography = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            person.name.isEmpty ? '人物详情' : person.name,
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
              // 人物主标题与详情页其它标题保持统一字体。
              fontFamily: 'Microsoft YaHei UI',
              fontWeight: FontWeight.w600,
            ),
          ),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 14,
              runSpacing: 10,
              children:
                  facts
                      .map(
                        (fact) => Text(
                          fact,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      )
                      .toList(),
            ),
          ],
          const SizedBox(height: 20),
          Tooltip(
            message: person.isFavorite ? '取消收藏' : '收藏演员',
            child: SizedBox.square(
              dimension: 56,
              child: OutlinedButton(
                onPressed: favoriteBusy ? null : onFavorite,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child:
                    favoriteBusy
                        ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Icon(
                          person.isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: person.isFavorite ? colors.error : null,
                          size: 28,
                        ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            person.overview.isEmpty ? '暂无简介' : person.overview,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(height: 1.72),
          ),
        ],
      );
      final infoCards = _personInfoCards(context, person);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (useWideHero)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                poster,
                const SizedBox(width: 30),
                Expanded(child: biography),
              ],
            )
          else ...[
            Center(child: poster),
            const SizedBox(height: 22),
            biography,
          ],
          if (infoCards.isNotEmpty) ...[
            const SizedBox(height: 32),
            _SectionTitle(icon: Icons.person_outline, title: '人物信息'),
            const SizedBox(height: 14),
            // 人物信息卡片在桌面端双列展示，窄屏自动切换为单列。
            LayoutBuilder(
              builder: (context, infoConstraints) {
                const spacing = 14.0;
                final cardWidth =
                    infoConstraints.maxWidth >= 560
                        ? (infoConstraints.maxWidth - spacing) / 2
                        : infoConstraints.maxWidth;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children:
                      infoCards
                          .map(
                            (card) => SizedBox(width: cardWidth, child: card),
                          )
                          .toList(),
                );
              },
            ),
          ],
          const SizedBox(height: 32),
          _SectionTitle(
            icon: Icons.movie_outlined,
            title: '参演作品',
            trailing: '${items.length}',
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Text('暂未找到关联作品'),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columnCount(constraints.maxWidth),
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 0.72,
              ),
              itemBuilder:
                  (context, index) => EmbyPcMediaTile(
                    item: items[index],
                    imageStyle: 'poster',
                    onOpen: () => onOpenItem(items[index]),
                  ),
            ),
        ],
      );
    },
  );

  // 摘要字段沿用 Vue 人物页的顺序，空值不占据布局空间。
  List<String> _personFacts(EmbyPcItem person) => [
    if (person.type.isNotEmpty) '类型：${_typeLabel(person.type)}',
    if (person.sortName.isNotEmpty) '排序名：${person.sortName}',
    if (person.premiereDate.isNotEmpty)
      '首映日期：${_formatDate(person.premiereDate)}',
    if (person.dateCreated.isNotEmpty)
      '添加日期：${_formatDate(person.dateCreated)}',
  ];

  // 流派等已有资料与新增外部资料统一使用相同的信息卡片样式。
  List<Widget> _personInfoCards(BuildContext context, EmbyPcItem person) {
    final cards = <Widget>[];
    if (person.genres.isNotEmpty) {
      cards.add(
        _PersonInfoCard(
          icon: Icons.image_outlined,
          title: '流派',
          children: [Text(person.genres.join('、'))],
        ),
      );
    }
    if (person.tags.isNotEmpty) {
      cards.add(
        _PersonInfoCard(
          icon: Icons.sell_outlined,
          title: '标签',
          children: [Text(person.tags.join('、'))],
        ),
      );
    }
    final studioNames =
        person.studios
            .map((studio) => studio.name)
            .where((name) => name.isNotEmpty)
            .toList();
    if (studioNames.isNotEmpty) {
      cards.add(
        _PersonInfoCard(
          icon: Icons.videocam_outlined,
          title: '工作室',
          children: [Text(studioNames.join('、'))],
        ),
      );
    }
    if (person.providerIds.isNotEmpty) {
      cards.add(
        _PersonInfoCard(
          icon: Icons.calendar_month_outlined,
          title: '外部编号',
          children:
              person.providerIds.entries
                  .map((entry) => Text('${entry.key}：${entry.value}'))
                  .toList(),
        ),
      );
    }
    final externalUrls = person.externalUrls.where(
      (external) => external.url.isNotEmpty,
    );
    if (externalUrls.isNotEmpty) {
      cards.add(
        _PersonInfoCard(
          icon: Icons.link,
          title: '外部链接',
          // 当前项目未引入 URL 启动依赖，先以可选择文本展示并通过提示显示完整地址。
          children:
              externalUrls
                  .map(
                    (external) => Tooltip(
                      message: external.url,
                      child: SelectableText(
                        external.name.isEmpty ? external.url : external.name,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  )
                  .toList(),
        ),
      );
    }
    return cards;
  }

  String _typeLabel(String type) => switch (type) {
    'Movie' => '电影',
    'Series' => '剧集',
    'Video' => '视频',
    'Episode' => '单集',
    'Person' => '人物',
    _ => type,
  };

  String _formatDate(String value) {
    final date = DateTime.tryParse(value);
    if (date == null) return value;
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}/$month/$day';
  }

  int _columnCount(double width) {
    if (width >= 1050) return 6;
    if (width >= 780) return 5;
    if (width >= 560) return 4;
    if (width >= 360) return 3;
    return 2;
  }
}

// 人物信息和作品区域复用一致的图标标题及 Windows 中文 UI 字体。
class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String trailing;

  const _SectionTitle({
    required this.icon,
    required this.title,
    this.trailing = '',
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 22),
      const SizedBox(width: 8),
      Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontFamily: 'Microsoft YaHei UI',
          fontWeight: FontWeight.w600,
        ),
      ),
      if (trailing.isNotEmpty) ...[
        const SizedBox(width: 8),
        Text(trailing, style: Theme.of(context).textTheme.bodySmall),
      ],
    ],
  );
}

// 卡片视觉沿用参考页面的浅边框、圆角和紧凑内容间距。
class _PersonInfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _PersonInfoCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant.withOpacity(0.7)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          ...children.expand(
            (child) => [
              DefaultTextStyle(
                style: (Theme.of(context).textTheme.bodyMedium ??
                        const TextStyle())
                    .copyWith(color: colors.onSurfaceVariant, height: 1.5),
                child: child,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ],
      ),
    );
  }
}

class _PersonError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _PersonError({required this.message, required this.onRetry});

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
