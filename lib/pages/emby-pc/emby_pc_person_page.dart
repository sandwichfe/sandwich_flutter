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
      final value = await EmbyPcService.instance.setFavorite(person.id, !person.isFavorite);
      if (mounted) setState(() => _person = person.copyWith(isFavorite: value));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? _PersonError(message: _error, onRetry: _loadPerson)
              : person == null
                  ? const Center(child: Text('没有可显示的人物资料'))
                  : CustomScrollView(
                      slivers: [
                        SliverAppBar(
                          pinned: true,
                          expandedHeight: 250,
                          title: Text(person.name.isEmpty ? widget.personName : person.name),
                          flexibleSpace: FlexibleSpaceBar(
                            background: Stack(
                              fit: StackFit.expand,
                              children: [
                                EmbyPcNetworkImage(
                                  url: person.hasBackdropImage
                                      ? EmbyPcService.instance.imageUrl(
                                          person.id,
                                          type: 'Backdrop',
                                          maxWidth: 1400,
                                        )
                                      : '',
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black.withOpacity(0.1),
                                        colors.surface.withOpacity(0.96),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
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
                                  onOpenItem: (item) => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => EmbyPcDetailPage(item: item),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
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
      final poster = SizedBox(
        width: 180,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: EmbyPcNetworkImage(
              url: person.hasPrimaryImage
                  ? EmbyPcService.instance.imageUrl(person.id, maxWidth: 420)
                  : '',
            ),
          ),
        ),
      );
      final biography = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            person.name,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            person.overview.isEmpty ? '暂无简介' : person.overview,
            style: const TextStyle(height: 1.65),
          ),
          if (person.genres.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('相关类型：${person.genres.join('、')}'),
          ],
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: favoriteBusy ? null : onFavorite,
            icon: favoriteBusy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    person.isFavorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                  ),
            label: Text(person.isFavorite ? '已收藏' : '收藏演员'),
          ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (constraints.maxWidth >= 680)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [poster, const SizedBox(width: 28), Expanded(child: biography)],
            )
          else ...[
            Center(child: poster),
            const SizedBox(height: 22),
            biography,
          ],
          const SizedBox(height: 32),
          Text(
            '参演作品  ${items.length}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
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
              itemBuilder: (context, index) => EmbyPcMediaTile(
                item: items[index],
                imageStyle: 'poster',
                onOpen: () => onOpenItem(items[index]),
              ),
            ),
        ],
      );
    },
  );

  int _columnCount(double width) {
    if (width >= 1050) return 6;
    if (width >= 780) return 5;
    if (width >= 560) return 4;
    if (width >= 360) return 3;
    return 2;
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
