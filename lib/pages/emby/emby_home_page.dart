import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/emby_models.dart';
import '../../services/emby_service.dart';
import 'emby_favorites_page.dart';
import 'emby_login_page.dart';
import 'emby_stream_page.dart';
import 'emby_video_feed_page.dart';

class EmbyHomePage extends StatefulWidget {
  const EmbyHomePage({super.key});

  @override
  State<EmbyHomePage> createState() => _EmbyHomePageState();
}

class _EmbyHomePageState extends State<EmbyHomePage> {
  static const int _pageSize = 150;

  List<EmbyLibrary> _libraries = [];
  final Random _random = Random();
  bool _loading = true;
  String? _openingLibraryId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final libs = await EmbyService().getLibraries();
      setState(() {
        _libraries = libs;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    await EmbyService().logout();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const EmbyLoginPage()),
      );
    }
  }

  Future<void> _openLibrary(EmbyLibrary library) async {
    if (_openingLibraryId != null) return;

    setState(() => _openingLibraryId = library.id);
    try {
      final isRandomMode = await _isRandomPlaybackMode();
      final result = await EmbyService().getItems(
        parentId: library.id,
        limit: _pageSize,
      );
      var items = result.items;
      final total = result.total;
      if (items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('暂无视频')));
        }
        return;
      }

      if (isRandomMode && items.length < total) {
        items = await _loadAllLibraryItems(library, items, total);
      }

      if (!mounted) return;
      final initialIndex = isRandomMode ? _random.nextInt(items.length) : 0;
      setState(() => _openingLibraryId = null);
      await Navigator.of(context).push<EmbyStreamResult>(
        MaterialPageRoute(
          builder:
              (_) => EmbyStreamPage(
                items: items,
                initialIndex: initialIndex,
                totalCount: total,
                onLoadMore:
                    (startIndex) => EmbyService().getItems(
                      parentId: library.id,
                      limit: _pageSize,
                      startIndex: startIndex,
                    ),
                onOpenGridPage:
                    (streamResult) =>
                        _openGridPageFromStream(library, streamResult),
              ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted && _openingLibraryId == library.id) {
        setState(() => _openingLibraryId = null);
      }
    }
  }

  Future<bool> _isRandomPlaybackMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(embyPlaybackModeStorageKey) ==
        embyRandomPlaybackModeValue;
  }

  Future<List<EmbyItem>> _loadAllLibraryItems(
    EmbyLibrary library,
    List<EmbyItem> initialItems,
    int total,
  ) async {
    final items = List<EmbyItem>.of(initialItems);
    final knownIds = items.map((e) => e.id).toSet();

    while (items.length < total) {
      final result = await EmbyService().getItems(
        parentId: library.id,
        limit: _pageSize,
        startIndex: items.length,
      );
      final newItems =
          result.items.where((item) => knownIds.add(item.id)).toList();
      if (newItems.isEmpty) break;
      items.addAll(newItems);
    }

    return items;
  }

  Future<void> _openGridPageFromStream(
    EmbyLibrary library,
    EmbyStreamResult result,
  ) async {
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder:
            (_) => EmbyVideoFeedPage(
              library: library,
              initialItems: result.items,
              initialTotalCount: result.totalCount,
              initialPlayingIndex: result.currentIndex,
              initialPlayingItemId:
                  result.currentIndex >= 0 &&
                          result.currentIndex < result.items.length
                      ? result.items[result.currentIndex].id
                      : null,
              initialPlaybackPosition: result.currentPosition,
              openInitialStream: false,
            ),
      ),
    );
  }

  IconData _libIcon(String type) {
    switch (type) {
      case 'movies':
        return Icons.movie;
      case 'tvshows':
        return Icons.tv;
      case 'music':
        return Icons.music_note;
      default:
        return Icons.folder;
    }
  }

  EmbyLibrary? _openingLibrary() {
    for (final library in _libraries) {
      if (library.id == _openingLibraryId) return library;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final openingLibrary = _openingLibrary();

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Text('媒体库'),
            actions: [
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: _openingLibraryId == null ? _logout : null,
              ),
            ],
          ),
          body: _buildBody(),
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child:
                openingLibrary == null
                    ? const SizedBox.shrink()
                    : _OpeningLibraryOverlay(
                      key: ValueKey(openingLibrary.id),
                      libraryName: openingLibrary.name,
                    ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_libraries.isEmpty) {
      return const Center(child: Text('没有媒体库'));
    }

    return ListView(
      children: [
        ListTile(
          leading: Icon(Icons.favorite, color: Colors.red.shade400),
          title: const Text('我的收藏'),
          trailing: const Icon(Icons.chevron_right),
          enabled: _openingLibraryId == null,
          onTap:
              _openingLibraryId == null
                  ? () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const EmbyFavoritesPage(),
                    ),
                  )
                  : null,
        ),
        const Divider(height: 1),
        ..._libraries.map((lib) {
          final opening = _openingLibraryId == lib.id;
          final colorScheme = Theme.of(context).colorScheme;

          return ListTile(
            leading: Icon(
              _libIcon(lib.collectionType),
              color: colorScheme.primary,
            ),
            title: Text(lib.name),
            tileColor:
                opening ? colorScheme.primary.withValues(alpha: 0.08) : null,
            trailing:
                opening
                    ? Icon(
                      Icons.hourglass_top_rounded,
                      color: colorScheme.primary,
                    )
                    : const Icon(Icons.chevron_right),
            onTap: _openingLibraryId == null ? () => _openLibrary(lib) : null,
          );
        }),
      ],
    );
  }
}

class _OpeningLibraryOverlay extends StatelessWidget {
  final String libraryName;

  const _OpeningLibraryOverlay({super.key, required this.libraryName});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: AbsorbPointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.scrim.withValues(alpha: 0.42),
          ),
          child: Center(
            child: Container(
              width: 220,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      strokeCap: StrokeCap.round,
                      color: colorScheme.primary,
                      backgroundColor: colorScheme.primary.withValues(
                        alpha: 0.12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '正在打开',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    libraryName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
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
}
