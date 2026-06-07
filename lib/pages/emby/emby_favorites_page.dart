import 'package:flutter/material.dart';
import '../../models/emby_models.dart';
import '../../services/emby_service.dart';
import 'emby_stream_page.dart';

class EmbyFavoritesPage extends StatefulWidget {
  const EmbyFavoritesPage({super.key});

  @override
  State<EmbyFavoritesPage> createState() => _EmbyFavoritesPageState();
}

class _EmbyFavoritesPageState extends State<EmbyFavoritesPage> {
  static const int _gridColumnCount = 3;
  static const double _gridPadding = 4;
  static const double _gridSpacing = 4;
  static const double _gridChildAspectRatio = 9 / 16;

  List<EmbyItem> _items = [];
  final ScrollController _scrollCtrl = ScrollController();
  int _total = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({int startIndex = 0}) async {
    setState(() => _loading = true);
    try {
      final result = await EmbyService().getFavorites(startIndex: startIndex);
      setState(() {
        if (startIndex == 0) {
          _items = result.items;
        } else {
          _items = [..._items, ...result.items];
        }
        _total = result.total;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openStream(int index) async {
    final result = await Navigator.of(context).push<EmbyStreamResult>(
      MaterialPageRoute(
        builder:
            (_) => EmbyStreamPage(
              items: _items,
              initialIndex: index,
              totalCount: _total,
              onLoadMore:
                  (startIndex) =>
                      EmbyService().getFavorites(startIndex: startIndex),
            ),
      ),
    );
    if (!mounted || result == null) return;

    String? scrollTargetItemId;
    setState(() {
      for (final item in result.items) {
        final i = _items.indexWhere((e) => e.id == item.id);
        if (!item.isFavorite) {
          if (i != -1) _items.removeAt(i);
        } else if (i != -1) {
          _items[i] = item;
        } else {
          _items.add(item);
        }
      }
      _total = result.totalCount ?? _total;
      if (_total < _items.length) _total = _items.length;
      if (result.currentIndex >= 0 &&
          result.currentIndex < result.items.length &&
          result.items[result.currentIndex].isFavorite) {
        scrollTargetItemId = result.items[result.currentIndex].id;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCard(scrollTargetItemId);
    });
  }

  void _scrollToCard(String? itemId) {
    if (itemId == null || !_scrollCtrl.hasClients) return;

    final index = _items.indexWhere((e) => e.id == itemId);
    if (index == -1) return;

    final gridWidth = MediaQuery.sizeOf(context).width;
    final tileWidth =
        (gridWidth -
            (_gridPadding * 2) -
            (_gridSpacing * (_gridColumnCount - 1))) /
        _gridColumnCount;
    if (tileWidth <= 0) return;

    final row = index ~/ _gridColumnCount;
    final rowHeight = tileWidth / _gridChildAspectRatio;
    final offset = _gridPadding + row * (rowHeight + _gridSpacing);
    final safeOffset = offset.clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.jumpTo(safeOffset.toDouble());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的收藏')),
      body:
          _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? const Center(child: Text('暂无收藏'))
              : Column(
                children: [
                  Expanded(
                    child: GridView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(_gridPadding),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: _gridColumnCount,
                            childAspectRatio: _gridChildAspectRatio,
                            crossAxisSpacing: _gridSpacing,
                            mainAxisSpacing: _gridSpacing,
                          ),
                      itemCount: _items.length,
                      itemBuilder:
                          (_, i) => _FavTile(
                            item: _items[i],
                            onTap: () => _openStream(i),
                          ),
                    ),
                  ),
                  if (_items.length < _total)
                    TextButton(
                      onPressed: () => _load(startIndex: _items.length),
                      child: Text('加载更多 (${_items.length}/$_total)'),
                    ),
                ],
              ),
    );
  }
}

class _FavTile extends StatelessWidget {
  final EmbyItem item;
  final VoidCallback onTap;
  const _FavTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final thumb = EmbyService().getThumbnailUrl(item.id);
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            thumb,
            fit: BoxFit.cover,
            errorBuilder:
                (_, __, ___) => Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.movie),
                ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Text(
                item.name,
                style: const TextStyle(color: Colors.white, fontSize: 10),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
