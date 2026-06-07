import 'package:flutter/material.dart';
import '../../models/emby_models.dart';
import '../../services/emby_service.dart';
import 'emby_stream_page.dart';

class EmbyVideoFeedPage extends StatefulWidget {
  final EmbyLibrary library;
  const EmbyVideoFeedPage({super.key, required this.library});

  @override
  State<EmbyVideoFeedPage> createState() => _EmbyVideoFeedPageState();
}

class _EmbyVideoFeedPageState extends State<EmbyVideoFeedPage> {
  static const int _gridColumnCount = 3;
  static const double _gridPadding = 4;
  static const double _gridSpacing = 4;
  static const double _gridChildAspectRatio = 9 / 16;
  static const int _pageSize = 150;

  final List<EmbyItem> _items = [];
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  int _total = 0;
  bool _loading = false;
  bool _openedInitialStream = false;
  bool _streamOpen = false;
  bool _showBackToTop = false;
  String _searchTerm = '';
  int _requestId = 0;
  String? _currentPlayingItemId;
  int? _currentPlayingIndex;
  final Map<String, Duration> _playbackPositions = {};

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  Future<void> _load({int startIndex = 0, bool force = false}) async {
    if (_loading && !force) return;
    final requestId = ++_requestId;
    var shouldOpenInitialStream = false;
    setState(() => _loading = true);
    try {
      final result = await EmbyService().getItems(
        parentId: widget.library.id,
        limit: _pageSize,
        startIndex: startIndex,
        searchTerm: _searchTerm,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        if (startIndex == 0) _items.clear();
        _items.addAll(result.items);
        _total = result.total;
      });
      if (startIndex == 0 && !_openedInitialStream && _searchTerm.isEmpty) {
        _openedInitialStream = true;
        shouldOpenInitialStream = result.items.isNotEmpty;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted && requestId == _requestId) setState(() => _loading = false);
    }

    if (shouldOpenInitialStream && mounted && requestId == _requestId) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) await _openStream(0);
    }
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;

    final position = _scrollCtrl.position;
    final shouldShowBackToTop = position.pixels > 360;
    if (shouldShowBackToTop != _showBackToTop) {
      setState(() => _showBackToTop = shouldShowBackToTop);
    }

    if (_loading || _items.length >= _total) return;
    if (position.pixels >= position.maxScrollExtent - 300) {
      _load(startIndex: _items.length);
    }
  }

  void _search() {
    FocusScope.of(context).unfocus();
    final keyword = _searchCtrl.text.trim();
    if (keyword == _searchTerm) return;
    setState(() {
      _searchTerm = keyword;
      _items.clear();
      _total = 0;
    });
    _load(force: true);
  }

  void _clearSearch() {
    if (_searchCtrl.text.isEmpty && _searchTerm.isEmpty) return;
    _searchCtrl.clear();
    _search();
  }

  int _validStreamIndex(int index) {
    if (_items.isEmpty || index < 0) return 0;
    if (index >= _items.length) return _items.length - 1;
    return index;
  }

  int _resumeStreamIndex() {
    final itemId = _currentPlayingItemId;
    if (itemId != null) {
      final index = _items.indexWhere((e) => e.id == itemId);
      if (index != -1) return index;
      return 0;
    }
    final index = _currentPlayingIndex;
    return index == null ? 0 : _validStreamIndex(index);
  }

  Future<void> _openCurrentStream() => _openStream(_resumeStreamIndex());

  Future<void> _openStream(int index) async {
    if (_items.isEmpty || _streamOpen) return;

    final initialIndex = _validStreamIndex(index);
    final initialItemId = _items[initialIndex].id;
    _streamOpen = true;
    _currentPlayingIndex = initialIndex;
    _currentPlayingItemId = initialItemId;

    final result = await Navigator.of(context).push<EmbyStreamResult>(
      MaterialPageRoute(
        builder:
            (_) => EmbyStreamPage(
              items: _items,
              initialIndex: initialIndex,
              totalCount: _total,
              onLoadMore:
                  (startIndex) => EmbyService().getItems(
                    parentId: widget.library.id,
                    limit: _pageSize,
                    startIndex: startIndex,
                    searchTerm: _searchTerm,
                  ),
              initialPosition:
                  _playbackPositions[initialItemId] ?? Duration.zero,
            ),
      ),
    );
    _streamOpen = false;
    if (!mounted) return;
    if (result != null) {
      String? scrollTargetItemId;
      setState(() {
        for (final u in result.items) {
          final i = _items.indexWhere((e) => e.id == u.id);
          if (i != -1) {
            _items[i] = u;
          } else {
            _items.add(u);
          }
        }
        _total = result.totalCount ?? _total;
        _currentPlayingIndex = _validStreamIndex(result.currentIndex);
        if (result.currentIndex >= 0 &&
            result.currentIndex < result.items.length) {
          _currentPlayingItemId = result.items[result.currentIndex].id;
          _playbackPositions[_currentPlayingItemId!] = result.currentPosition;
          scrollTargetItemId = _currentPlayingItemId;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCard(scrollTargetItemId);
      });
    }
  }

  void _scrollToCard(String? itemId) {
    if (!_scrollCtrl.hasClients) return;

    var index = -1;
    if (itemId != null) {
      index = _items.indexWhere((e) => e.id == itemId);
    }
    if (index == -1) {
      final fallbackIndex = _currentPlayingIndex;
      if (fallbackIndex == null) return;
      index = _validStreamIndex(fallbackIndex);
    }

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

  void _scrollToTop() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.library.name),
        actions: [
          IconButton(
            tooltip: '继续播放',
            icon: const Icon(Icons.view_stream),
            onPressed: _items.isEmpty ? null : _openCurrentStream,
          ),
        ],
      ),
      floatingActionButton:
          _items.isEmpty
              ? null
              : AnimatedScale(
                scale: _showBackToTop ? 1 : 0.88,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: _showBackToTop ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !_showBackToTop,
                    child: _buildBackToTopButton(),
                  ),
                ),
              ),
      body: _buildBody(),
    );
  }

  Widget _buildBackToTopButton() {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      minimum: const EdgeInsets.only(right: 2, bottom: 4),
      child: Tooltip(
        message: '回到顶部',
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          elevation: 3,
          shadowColor: colorScheme.shadow.withValues(alpha: 0.24),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _scrollToTop,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 22,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '顶部',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        _buildSearchField(),
        Expanded(
          child:
              _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _buildGrid(),
        ),
      ],
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索视频',
                prefixIcon: const Icon(Icons.search),
                suffixIcon:
                    _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                          tooltip: '清空',
                          icon: const Icon(Icons.clear),
                          onPressed: _clearSearch,
                        ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 48,
            width: 48,
            child: IconButton.outlined(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: _search,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    if (_items.isEmpty) return const Center(child: Text('暂无视频'));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              Text(
                '总视频数：$_total',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(width: 8),
              Text(
                '已加载：${_items.length}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.all(_gridPadding),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _gridColumnCount,
              childAspectRatio: _gridChildAspectRatio,
              crossAxisSpacing: _gridSpacing,
              mainAxisSpacing: _gridSpacing,
            ),
            itemCount: _items.length,
            itemBuilder:
                (_, i) => _GridTile(
                  item: _items[i],
                  isRecentlyWatched: _items[i].id == _currentPlayingItemId,
                  onTap: () => _openStream(i),
                ),
          ),
        ),
        if (_loading && _items.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

class _GridTile extends StatelessWidget {
  final EmbyItem item;
  final bool isRecentlyWatched;
  final VoidCallback onTap;
  const _GridTile({
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.runTimeTicks > 0)
                    Text(
                      item.durationLabel,
                      style: const TextStyle(color: Colors.grey, fontSize: 9),
                    ),
                ],
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
