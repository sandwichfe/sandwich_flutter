import 'package:flutter/material.dart';

import 'emby_pc_detail_page.dart';
import 'emby_pc_login_page.dart';
import 'emby_pc_models.dart';
import 'emby_pc_person_page.dart';
import 'emby_pc_player_page.dart';
import 'emby_pc_service.dart';
import 'emby_pc_widgets.dart';

// 入口页负责先恢复桌面会话，再决定展示登录页还是媒体工作台。
class EmbyPcEntryPage extends StatefulWidget {
  const EmbyPcEntryPage({super.key});

  @override
  State<EmbyPcEntryPage> createState() => _EmbyPcEntryPageState();
}

class _EmbyPcEntryPageState extends State<EmbyPcEntryPage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    await EmbyPcService.instance.restoreSession();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!EmbyPcService.instance.isLoggedIn) {
      return EmbyPcLoginPage(
        onLogin: () => setState(() {}),
      );
    }
    return EmbyPcWorkspace(
      onLogout: () => setState(() {}),
    );
  }
}

class EmbyPcWorkspace extends StatefulWidget {
  final VoidCallback onLogout;

  const EmbyPcWorkspace({super.key, required this.onLogout});

  @override
  State<EmbyPcWorkspace> createState() => _EmbyPcWorkspaceState();
}

class _EmbyPcWorkspaceState extends State<EmbyPcWorkspace> {
  final _searchController = TextEditingController();
  final _yearController = TextEditingController();
  final _scrollController = ScrollController();
  List<EmbyPcItem> _libraries = const [];
  List<EmbyPcItem> _items = const [];
  final Map<String, int?> _libraryCounts = {};
  int? _favoriteMovieCount;
  int? _favoritePeopleCount;
  String _activeId = '';
  String _view = 'library';
  String _itemType = '';
  String _statusFilter = '';
  String _markFilter = '';
  String _videoType = '';
  String _sortBy = 'PremiereDate';
  String _sortOrder = 'Descending';
  String _imageStyle = 'backdrop';
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _countsLoading = true;
  bool _favoritePeopleLoading = false;
  bool _favoriteMovieLoading = false;
  bool _sidebarCollapsed = false;
  String _error = '';
  int _queryVersion = 0;
  final Set<String> _favoriteBusyIds = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final results = await Future.wait<dynamic>([
        EmbyPcService.instance.getLibraries(),
        EmbyPcService.instance.readPreferences(),
      ]);
      final libraries = results[0] as List<EmbyPcItem>;
      final preferences = results[1] as EmbyPcPreferences;
      final ordered = _applyLibraryOrder(libraries, preferences.libraryOrder);
      if (!mounted) return;
      setState(() {
        _libraries = ordered;
        _sortBy = preferences.sortBy;
        _sortOrder = preferences.sortOrder;
        _imageStyle = preferences.imageStyle == 'poster' ? 'poster' : 'backdrop';
        _activeId = ordered.isEmpty ? '' : ordered.first.id;
        _loading = false;
      });
      _loadCounts(ordered);
      if (_activeId.isNotEmpty) await _loadItems(reset: true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  List<EmbyPcItem> _applyLibraryOrder(
    List<EmbyPcItem> libraries,
    List<String> savedOrder,
  ) {
    if (savedOrder.isEmpty) return libraries;
    final byId = {for (final item in libraries) item.id: item};
    final ordered = <EmbyPcItem>[];
    for (final id in savedOrder) {
      final item = byId.remove(id);
      if (item != null) ordered.add(item);
    }
    ordered.addAll(byId.values);
    return ordered;
  }

  void _loadCounts(List<EmbyPcItem> libraries) {
    setState(() => _countsLoading = true);
    for (final library in libraries) {
      _loadLibraryCount(library.id);
    }
    setState(() {
      _favoriteMovieLoading = true;
      _favoritePeopleLoading = true;
    });
    _loadFavoriteCounts();
  }

  Future<void> _loadLibraryCount(String libraryId) async {
    try {
      final page = await EmbyPcService.instance.getItems(libraryId: libraryId, limit: 1);
      if (mounted) setState(() => _libraryCounts[libraryId] = page.total);
    } catch (_) {
      if (mounted) setState(() => _libraryCounts[libraryId] = null);
    }
  }

  Future<void> _loadFavoriteCounts() async {
    try {
      final results = await Future.wait<dynamic>([
        EmbyPcService.instance.getItems(favoriteOnly: true, limit: 1),
        EmbyPcService.instance.getItems(
          favoriteOnly: true,
          itemType: 'Person',
          limit: 1,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _favoriteMovieCount = (results[0] as EmbyPcPage).total;
        _favoritePeopleCount = (results[1] as EmbyPcPage).total;
        _favoriteMovieLoading = false;
        _favoritePeopleLoading = false;
        _countsLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _favoriteMovieCount = null;
          _favoritePeopleCount = null;
          _favoriteMovieLoading = false;
          _favoritePeopleLoading = false;
          _countsLoading = false;
        });
      }
    }
  }

  Future<void> _loadItems({required bool reset}) async {
    if ((!reset && _loadingMore) || (!reset && _items.length >= _total && _total > 0)) return;
    final requestVersion = reset ? ++_queryVersion : _queryVersion;
    if (reset) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = '';
        _items = const [];
        _total = 0;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = await EmbyPcService.instance.getItems(
        libraryId: _view == 'library' ? _activeId : '',
        favoriteOnly: _view == 'favorite-movies' || _view == 'favorite-people',
        startIndex: reset ? 0 : _items.length,
        itemType: _view == 'favorite-people' ? 'Person' : _itemType,
        filters: _view == 'favorite-movies' || _view == 'favorite-people'
            ? ''
            : <String>[_statusFilter, _markFilter]
                  .where((value) => value.isNotEmpty)
                  .join(','),
        videoType: _videoType,
        searchTerm: _searchController.text,
        productionYear: int.tryParse(_yearController.text.trim()),
        sortBy: _sortBy,
        sortOrder: _sortOrder,
      );
      if (!mounted || requestVersion != _queryVersion) return;
      setState(() {
        _items = reset ? page.items : [..._items, ...page.items];
        _total = page.total;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (mounted && requestVersion == _queryVersion) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = error.toString();
        });
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 700 && !_loading && !_loadingMore) {
      _loadItems(reset: false);
    }
  }

  Future<void> _selectLibrary(String id) async {
    if (id.isEmpty || (_view == 'library' && id == _activeId)) return;
    setState(() {
      _view = 'library';
      _activeId = id;
      _resetQueryControllers();
    });
    await _loadItems(reset: true);
  }

  Future<void> _selectFavorites(String view) async {
    if (_view == view) return;
    setState(() {
      _view = view;
      _activeId = '';
      _resetQueryControllers();
    });
    await _loadItems(reset: true);
  }

  void _resetQueryControllers() {
    _searchController.clear();
    _yearController.clear();
    _itemType = '';
    _statusFilter = '';
    _markFilter = '';
    _videoType = '';
  }

  Future<void> _applyQuery() async {
    await EmbyPcService.instance.saveListPreferences(
      sortBy: _sortBy,
      sortOrder: _sortOrder,
      imageStyle: _imageStyle,
    );
    await _loadItems(reset: true);
  }

  Future<void> _toggleFavorite(EmbyPcItem item) async {
    if (_favoriteBusyIds.contains(item.id)) return;
    setState(() => _favoriteBusyIds.add(item.id));
    try {
      final value = await EmbyPcService.instance.setFavorite(item.id, !item.isFavorite);
      if (!mounted) return;
      final updated = item.copyWith(isFavorite: value);
      setState(() {
        _items = _items.map((entry) => entry.id == item.id ? updated : entry).toList();
        if (!value && _view == 'favorite-movies') {
          _items = _items.where((entry) => entry.id != item.id).toList();
          _total = (_total - 1).clamp(0, 1 << 30).toInt();
        }
        if (_view == 'favorite-movies' && _favoriteMovieCount != null) {
          _favoriteMovieCount = (_favoriteMovieCount! + (value ? 1 : -1)).clamp(0, 1 << 30).toInt();
        }
        if (_view == 'favorite-people' && _favoritePeopleCount != null) {
          _favoritePeopleCount = (_favoritePeopleCount! + (value ? 1 : -1)).clamp(0, 1 << 30).toInt();
        }
      });
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _favoriteBusyIds.remove(item.id));
    }
  }

  Future<void> _openOrderDialog() async {
    final draft = List<EmbyPcItem>.of(_libraries);
    final saved = await showDialog<List<EmbyPcItem>>(
      context: context,
      builder: (context) => _LibraryOrderDialog(libraries: draft),
    );
    if (saved == null || !mounted) return;
    await EmbyPcService.instance.saveLibraryOrder(saved.map((item) => item.id).toList());
    setState(() {
      _libraries = saved;
      if (_view == 'library' && !_libraries.any((item) => item.id == _activeId)) {
        _activeId = _libraries.isEmpty ? '' : _libraries.first.id;
      }
    });
  }

  Future<void> _logout() async {
    await EmbyPcService.instance.logout();
    if (mounted) widget.onLogout();
  }

  void _openItem(EmbyPcItem item) {
    if (_view == 'favorite-people') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EmbyPcPersonPage(personId: item.id, personName: item.name),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EmbyPcDetailPage(item: item)),
    );
  }

  void _playItem(EmbyPcItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmbyPcPlayerPage(
          item: item,
          startPositionTicks: item.playbackPositionTicks,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _yearController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 820;
        return Scaffold(
          appBar: AppBar(
            title: Text(_pageTitle),
            leading: compact
                ? PopupMenuButton<String>(
                    tooltip: '切换内容',
                    icon: const Icon(Icons.menu),
                    onSelected: (value) {
                      if (value == 'order') {
                        _openOrderDialog();
                      } else if (value == 'favorite-movies' || value == 'favorite-people') {
                        _selectFavorites(value);
                      } else {
                        _selectLibrary(value);
                      }
                    },
                    itemBuilder: (_) => [
                      ..._libraries.map(
                        (library) => PopupMenuItem(value: library.id, child: Text(library.name)),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'favorite-movies', child: Text('喜欢的影片')),
                      const PopupMenuItem(value: 'favorite-people', child: Text('喜欢的演员')),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'order', child: Text('调整媒体库顺序')),
                    ],
                  )
                : null,
            actions: [
              if (!compact)
                IconButton(
                  tooltip: '调整媒体库顺序',
                  onPressed: _openOrderDialog,
                  icon: const Icon(Icons.swap_vert),
                ),
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : () => _loadItems(reset: true),
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                tooltip: '账号',
                onSelected: (value) {
                  if (value == 'logout') _logout();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    enabled: false,
                    child: Text(EmbyPcService.instance.currentUserName),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'logout', child: Text('退出登录')),
                ],
              ),
            ],
          ),
          body: _error.isNotEmpty && _libraries.isEmpty
              ? _WorkspaceError(message: _error, onRetry: _initialize)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!compact) _buildSidebar(context),
                    Expanded(child: _buildContent(context)),
                  ],
                ),
        );
      },
    );
  }

  String get _pageTitle {
    if (_view == 'favorite-movies') return '喜欢的影片';
    if (_view == 'favorite-people') return '喜欢的演员';
    for (final library in _libraries) {
      if (library.id == _activeId) return library.name;
    }
    return '媒体库';
  }

  Widget _buildSidebar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: _sidebarCollapsed ? 64 : 236,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(right: BorderSide(color: colors.outlineVariant)),
        ),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: _sidebarCollapsed ? '展开侧栏' : '收起侧栏',
                onPressed: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
                icon: Icon(_sidebarCollapsed ? Icons.chevron_right : Icons.chevron_left),
              ),
            ),
            if (!_sidebarCollapsed)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 10, 10, 8),
                      child: Text('媒体库', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    ..._libraries.map(
                      (library) => _SidebarButton(
                        icon: Icons.folder_outlined,
                        title: library.name,
                        count: _libraryCounts[library.id],
                        active: _view == 'library' && library.id == _activeId,
                        onPressed: () => _selectLibrary(library.id),
                      ),
                    ),
                    const Divider(height: 28),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 0, 10, 8),
                      child: Text('我喜欢的', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    _SidebarButton(
                      icon: Icons.movie_outlined,
                      title: '影片',
                      count: _favoriteMovieCount,
                      active: _view == 'favorite-movies',
                      loading: _favoriteMovieLoading,
                      onPressed: () => _selectFavorites('favorite-movies'),
                    ),
                    _SidebarButton(
                      icon: Icons.person_outline,
                      title: '演员',
                      count: _favoritePeopleCount,
                      active: _view == 'favorite-people',
                      loading: _favoritePeopleLoading,
                      onPressed: () => _selectFavorites('favorite-people'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        _buildToolbar(context),
        if (_error.isNotEmpty)
          MaterialBanner(
            content: Text(_error),
            actions: [
              TextButton(onPressed: () => _loadItems(reset: true), child: const Text('重试')),
            ],
          ),
        Expanded(
          child: _items.isEmpty
              ? const _EmptyState()
              : GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _imageStyle == 'backdrop' ? 320 : 220,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    childAspectRatio: _imageStyle == 'backdrop' ? 1.38 : 0.70,
                  ),
                  itemCount: _items.length + (_loadingMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= _items.length) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final item = _items[index];
                    return EmbyPcMediaTile(
                      item: item,
                      imageStyle: _imageStyle,
                      favoriteBusy: _favoriteBusyIds.contains(item.id),
                      onOpen: () => _openItem(item),
                      onPlay: _view == 'favorite-people' ? null : () => _playItem(item),
                      onFavorite: () => _toggleFavorite(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onSubmitted: (_) => _applyQuery(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索媒体',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              onPressed: () {
                                _searchController.clear();
                                _applyQuery();
                                setState(() {});
                              },
                              icon: const Icon(Icons.clear),
                            ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _applyQuery,
                  icon: const Icon(Icons.search),
                  label: Text(compact ? '搜索' : '应用'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _select<String>(
                  value: _itemType,
                  label: '类型',
                  options: const {'': '全部类型', 'Movie': '电影', 'Series': '剧集', 'Video': '视频'},
                  onChanged: (value) {
                    setState(() => _itemType = value ?? '');
                    _applyQuery();
                  },
                ),
                if (_view != 'favorite-movies' && _view != 'favorite-people')
                  _select<String>(
                    value: _statusFilter,
                    label: '观看',
                    options: const {
                      '': '全部状态',
                      'IsUnplayed': '未观看',
                      'IsPlayed': '已观看',
                      'IsResumable': '可继续',
                    },
                    onChanged: (value) {
                      setState(() => _statusFilter = value ?? '');
                      _applyQuery();
                    },
                  ),
                if (_view != 'favorite-movies' && _view != 'favorite-people')
                  _select<String>(
                    value: _markFilter,
                    label: '偏好',
                    options: const {'': '全部偏好', 'IsFavorite': '收藏', 'Likes': '喜欢', 'Dislikes': '不喜欢'},
                    onChanged: (value) {
                      setState(() => _markFilter = value ?? '');
                      _applyQuery();
                    },
                  ),
                if (_view != 'favorite-movies' && _view != 'favorite-people')
                  _select<String>(
                    value: _videoType,
                    label: '视频源',
                    options: const {
                      '': '全部视频',
                      'videofile': '视频文件',
                      'dvd': 'DVD',
                      'bluray': '蓝光',
                      'iso': 'ISO',
                    },
                    onChanged: (value) {
                      setState(() => _videoType = value ?? '');
                      _applyQuery();
                    },
                  ),
                _select<String>(
                  value: _sortBy,
                  label: '排序',
                  options: const {
                    'CommunityRating': '评分',
                    'Height': '分辨率',
                    'DateCreated': '加入日期',
                    'PremiereDate': '发行日期',
                    'DatePlayed': '播放日期',
                    'Runtime': '播放时长',
                    'SortName': '文件名',
                  },
                  onChanged: (value) {
                    setState(() => _sortBy = value ?? _sortBy);
                    _applyQuery();
                  },
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Descending', icon: Icon(Icons.south), label: Text('降序')),
                    ButtonSegment(value: 'Ascending', icon: Icon(Icons.north), label: Text('升序')),
                  ],
                  selected: {_sortOrder},
                  onSelectionChanged: (value) {
                    setState(() => _sortOrder = value.first);
                    _applyQuery();
                  },
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'backdrop', icon: Icon(Icons.view_agenda_outlined), label: Text('背景图')),
                    ButtonSegment(value: 'poster', icon: Icon(Icons.grid_view), label: Text('海报')),
                  ],
                  selected: {_imageStyle},
                  onSelectionChanged: (value) {
                    setState(() => _imageStyle = value.first);
                    _applyQuery();
                  },
                ),
                SizedBox(
                  width: 112,
                  child: TextField(
                    controller: _yearController,
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _applyQuery(),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '年份',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _select<T>({
    required String value,
    required String label,
    required Map<String, String> options,
    required ValueChanged<String?> onChanged,
  }) => SizedBox(
    width: 146,
    child: DropdownButtonFormField<String>(
      value: options.containsKey(value) ? value : options.keys.first,
      isDense: true,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: options.entries
          .map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value)))
          .toList(),
      onChanged: onChanged,
    ),
  );
}

class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final int? count;
  final bool active;
  final bool loading;
  final VoidCallback onPressed;

  const _SidebarButton({
    required this.icon,
    required this.title,
    required this.count,
    required this.active,
    this.loading = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: ListTile(
      dense: true,
      selected: active,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      leading: Icon(icon),
      title: Text(title, overflow: TextOverflow.ellipsis),
      trailing: loading
          ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(count == null ? '-' : '$count'),
      onTap: onPressed,
    ),
  );
}

class _LibraryOrderDialog extends StatefulWidget {
  final List<EmbyPcItem> libraries;

  const _LibraryOrderDialog({required this.libraries});

  @override
  State<_LibraryOrderDialog> createState() => _LibraryOrderDialogState();
}

class _LibraryOrderDialogState extends State<_LibraryOrderDialog> {
  late final List<EmbyPcItem> _libraries = List.of(widget.libraries);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('调整媒体库顺序'),
    content: SizedBox(
      width: 420,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 500),
        child: _libraries.isEmpty
            ? const Text('暂无媒体库')
            : ReorderableListView.builder(
                shrinkWrap: true,
                itemCount: _libraries.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final item = _libraries.removeAt(oldIndex);
                    _libraries.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey(_libraries[index].id),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(_libraries[index].name),
                  trailing: const Icon(Icons.drag_handle),
                ),
              ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context, _libraries), child: const Text('保存')),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.movie_filter_outlined, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: 12),
        const Text('没有找到媒体'),
      ],
    ),
  );
}

class _WorkspaceError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _WorkspaceError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 52),
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
