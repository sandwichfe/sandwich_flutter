import 'package:flutter/material.dart';
import '../../models/emby_models.dart';
import '../../services/emby_service.dart';
import 'emby_stream_page.dart';

class EmbyFavoritesPage extends StatefulWidget {
  final List<EmbyItem>? initialItems;
  final int? initialTotalCount;
  final int? initialPlayingIndex;
  final String? initialPlayingItemId;
  final Duration? initialPlaybackPosition;

  const EmbyFavoritesPage({
    super.key,
    this.initialItems,
    this.initialTotalCount,
    this.initialPlayingIndex,
    this.initialPlayingItemId,
    this.initialPlaybackPosition,
  });

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
  String? _recentlyWatchedItemId;
  final Map<String, Duration> _playbackPositions = {};

  @override
  void initState() {
    super.initState();
    _seedInitialItems();
    if (_items.isEmpty) {
      _load();
    } else {
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCard(_recentlyWatchedItemId);
      });
    }
  }

  void _seedInitialItems() {
    final initialItems = widget.initialItems;
    if (initialItems == null || initialItems.isEmpty) return;

    _items = List.of(initialItems);
    _total = widget.initialTotalCount ?? initialItems.length;
    final initialPlayingIndex =
        widget.initialPlayingIndex == null
            ? null
            : _validStreamIndex(widget.initialPlayingIndex!);
    _recentlyWatchedItemId =
        widget.initialPlayingItemId ??
        (initialPlayingIndex == null ? null : _items[initialPlayingIndex].id);
    if (_recentlyWatchedItemId != null &&
        widget.initialPlaybackPosition != null) {
      _playbackPositions[_recentlyWatchedItemId!] =
          widget.initialPlaybackPosition!;
    }
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
    if (_items.isEmpty) return;

    final initialIndex = _validStreamIndex(index);
    final initialItemId = _items[initialIndex].id;
    final result = await Navigator.of(context).push<EmbyStreamResult>(
      MaterialPageRoute(
        builder:
            (_) => EmbyStreamPage(
              items: _items,
              initialIndex: initialIndex,
              totalCount: _total,
              onLoadMore:
                  (startIndex) =>
                      EmbyService().getFavorites(startIndex: startIndex),
              initialPosition:
                  _playbackPositions[initialItemId] ?? Duration.zero,
              onOpenGridPage: _openGridPageFromStream,
            ),
      ),
    );
    if (!mounted || result == null) return;

    _applyStreamResult(result);
  }

  Future<void> _openGridPageFromStream(EmbyStreamResult result) async {
    if (!mounted) return;

    await Navigator.of(context).push<EmbyStreamResult>(
      MaterialPageRoute(
        builder:
            (_) => EmbyFavoritesPage(
              initialItems: result.items,
              initialTotalCount: result.totalCount,
              initialPlayingIndex: result.currentIndex,
              initialPlayingItemId:
                  result.currentIndex >= 0 &&
                          result.currentIndex < result.items.length
                      ? result.items[result.currentIndex].id
                      : null,
              initialPlaybackPosition: result.currentPosition,
            ),
      ),
    );
  }

  void _applyStreamResult(EmbyStreamResult result) {
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
        _recentlyWatchedItemId = scrollTargetItemId;
        _playbackPositions[_recentlyWatchedItemId!] = result.currentPosition;
      } else {
        _recentlyWatchedItemId = null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCard(scrollTargetItemId);
    });
  }

  int _validStreamIndex(int index) {
    if (_items.isEmpty || index < 0) return 0;
    if (index >= _items.length) return _items.length - 1;
    return index;
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
                            isRecentlyWatched:
                                _items[i].id == _recentlyWatchedItemId,
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
  final bool isRecentlyWatched;
  final VoidCallback onTap;
  const _FavTile({
    required this.item,
    required this.isRecentlyWatched,
    required this.onTap,
  });

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
          if (isRecentlyWatched)
            const Positioned(top: 6, left: 6, child: _RecentlyWatchedBadge()),
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

class _RecentlyWatchedBadge extends StatelessWidget {
  const _RecentlyWatchedBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          '刚刚看过',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
