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
  List<EmbyItem> _items = [];
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
    });
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
                      padding: const EdgeInsets.all(4),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 9 / 16,
                            crossAxisSpacing: 4,
                            mainAxisSpacing: 4,
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
