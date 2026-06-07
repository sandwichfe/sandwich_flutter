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
  final List<EmbyItem> _items = [];
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  int _total = 0;
  bool _loading = false;
  bool _openedInitialStream = false;
  bool _streamOpen = false;
  static const int _pageSize = 150;
  String _searchTerm = '';
  int _requestId = 0;
  String? _currentPlayingItemId;
  int? _currentPlayingIndex;

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
    if (!_scrollCtrl.hasClients || _loading || _items.length >= _total) return;
    final position = _scrollCtrl.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      _load(startIndex: _items.length);
    }
  }

  void _search() {
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
    _streamOpen = true;
    _currentPlayingIndex = initialIndex;
    _currentPlayingItemId = _items[initialIndex].id;

    final result = await Navigator.of(context).push<EmbyStreamResult>(
      MaterialPageRoute(
        builder:
            (_) => EmbyStreamPage(items: _items, initialIndex: initialIndex),
      ),
    );
    _streamOpen = false;
    if (!mounted) return;
    if (result != null) {
      setState(() {
        for (final u in result.items) {
          final i = _items.indexWhere((e) => e.id == u.id);
          if (i != -1) _items[i] = u;
        }
        _currentPlayingIndex = _validStreamIndex(result.currentIndex);
        if (result.currentIndex >= 0 &&
            result.currentIndex < result.items.length) {
          _currentPlayingItemId = result.items[result.currentIndex].id;
        }
      });
    }
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
      body: _buildBody(),
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
                    icon: const Icon(Icons.clear),
                    onPressed: _clearSearch,
                  ),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _search(),
      ),
    );
  }

  Widget _buildGrid() {
    if (_items.isEmpty) return const Center(child: Text('暂无视频'));

    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 9 / 16,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: _items.length,
            itemBuilder:
                (_, i) =>
                    _GridTile(item: _items[i], onTap: () => _openStream(i)),
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
  final VoidCallback onTap;
  const _GridTile({required this.item, required this.onTap});

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
