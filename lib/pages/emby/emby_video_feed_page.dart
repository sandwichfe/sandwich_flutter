import 'package:flutter/material.dart';
import '../../models/emby_models.dart';
import '../../services/emby_service.dart';
import 'emby_stream_page.dart';

enum _ViewMode { stream, grid }

class EmbyVideoFeedPage extends StatefulWidget {
  final EmbyLibrary library;
  const EmbyVideoFeedPage({super.key, required this.library});

  @override
  State<EmbyVideoFeedPage> createState() => _EmbyVideoFeedPageState();
}

class _EmbyVideoFeedPageState extends State<EmbyVideoFeedPage> {
  final List<EmbyItem> _items = [];
  int _total = 0;
  bool _loading = true;
  _ViewMode _viewMode = _ViewMode.stream;
  static const int _pageSize = 150;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({int startIndex = 0}) async {
    setState(() => _loading = true);
    try {
      final result = await EmbyService().getItems(
        parentId: widget.library.id,
        limit: _pageSize,
        startIndex: startIndex,
      );
      setState(() {
        if (startIndex == 0) _items.clear();
        _items.addAll(result.items);
        _total = result.total;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  void _openStream(int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EmbyStreamPage(items: _items, initialIndex: index),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.library.name, style: const TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: Icon(
              _viewMode == _ViewMode.stream ? Icons.grid_view : Icons.view_stream,
              color: Colors.white,
            ),
            onPressed: () => setState(() {
              _viewMode = _viewMode == _ViewMode.stream ? _ViewMode.grid : _ViewMode.stream;
              if (_viewMode == _ViewMode.stream && _items.isNotEmpty) _openStream(0);
            }),
          ),
        ],
      ),
      body: _loading && _items.isEmpty
          ? const Center(child: CircularProgressIndicator(color: Colors.green))
          : _viewMode == _ViewMode.stream
              ? _buildStreamEntry()
              : _buildGrid(),
    );
  }

  Widget _buildStreamEntry() {
    if (_items.isEmpty) return const Center(child: Text('没有视频', style: TextStyle(color: Colors.grey)));
    return Center(
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14)),
        icon: const Icon(Icons.play_arrow, color: Colors.white),
        label: Text('播放 (${_items.length} 个视频)', style: const TextStyle(color: Colors.white)),
        onPressed: () => _openStream(0),
      ),
    );
  }

  Widget _buildGrid() {
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 9 / 16,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: _items.length,
            itemBuilder: (_, i) => _GridTile(item: _items[i], onTap: () => _openStream(i)),
          ),
        ),
        if (_items.length < _total)
          TextButton(
            onPressed: () => _load(startIndex: _items.length),
            child: Text('加载更多 (${_items.length}/$_total)', style: const TextStyle(color: Colors.green)),
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
          Image.network(thumb, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: Colors.grey[900], child: const Icon(Icons.movie, color: Colors.grey))),
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(gradient: LinearGradient(
                begin: Alignment.bottomCenter, end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              )),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: const TextStyle(color: Colors.white, fontSize: 10), maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (item.runTimeTicks > 0)
                    Text(item.durationLabel, style: const TextStyle(color: Colors.grey, fontSize: 9)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
