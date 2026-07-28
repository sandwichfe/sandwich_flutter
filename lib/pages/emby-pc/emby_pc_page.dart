import 'package:flutter/material.dart';

import '../settings_page.dart';
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
    if (_loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!EmbyPcService.instance.isLoggedIn) {
      return EmbyPcLoginPage(onLogin: () => setState(() {}));
    }
    return EmbyPcWorkspace(onLogout: () => setState(() {}));
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
        _imageStyle =
            preferences.imageStyle == 'poster' ? 'poster' : 'backdrop';
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
      final page = await EmbyPcService.instance.getItems(
        libraryId: libraryId,
        limit: 1,
      );
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
    if ((!reset && _loadingMore) ||
        (!reset && _items.length >= _total && _total > 0))
      return;
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
        filters:
            _view == 'favorite-movies' || _view == 'favorite-people'
                ? ''
                : <String>[
                  _statusFilter,
                  _markFilter,
                ].where((value) => value.isNotEmpty).join(','),
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
    if (_scrollController.position.extentAfter < 700 &&
        !_loading &&
        !_loadingMore) {
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

  Future<void> _clearSearch() async {
    if (_searchController.text.isEmpty) return;
    setState(_searchController.clear);
    await _applyQuery();
  }

  Future<void> _toggleFavorite(EmbyPcItem item) async {
    if (_favoriteBusyIds.contains(item.id)) return;
    setState(() => _favoriteBusyIds.add(item.id));
    try {
      final value = await EmbyPcService.instance.setFavorite(
        item.id,
        !item.isFavorite,
      );
      if (!mounted) return;
      final updated = item.copyWith(isFavorite: value);
      setState(() {
        _items =
            _items
                .map((entry) => entry.id == item.id ? updated : entry)
                .toList();
        if (!value && _view == 'favorite-movies') {
          _items = _items.where((entry) => entry.id != item.id).toList();
          _total = (_total - 1).clamp(0, 1 << 30).toInt();
        }
        if (_view == 'favorite-movies' && _favoriteMovieCount != null) {
          _favoriteMovieCount =
              (_favoriteMovieCount! + (value ? 1 : -1))
                  .clamp(0, 1 << 30)
                  .toInt();
        }
        if (_view == 'favorite-people' && _favoritePeopleCount != null) {
          _favoritePeopleCount =
              (_favoritePeopleCount! + (value ? 1 : -1))
                  .clamp(0, 1 << 30)
                  .toInt();
        }
      });
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
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
    await EmbyPcService.instance.saveLibraryOrder(
      saved.map((item) => item.id).toList(),
    );
    setState(() {
      _libraries = saved;
      if (_view == 'library' &&
          !_libraries.any((item) => item.id == _activeId)) {
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
          builder:
              (_) => EmbyPcPersonPage(personId: item.id, personName: item.name),
        ),
      );
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => EmbyPcDetailPage(item: item)));
  }

  void _playItem(EmbyPcItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => EmbyPcPlayerPage(
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
          body:
              _error.isNotEmpty && _libraries.isEmpty
                  ? _WorkspaceError(message: _error, onRetry: _initialize)
                  : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!compact) _buildSidebar(context),
                      Expanded(child: _buildContent(context, compact: compact)),
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

  Widget _buildSearchField(double width) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 42,
      child: TextField(
        controller: _searchController,
        enabled: !_loading,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _applyQuery(),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: colors.surface.withValues(alpha: 0.82),
          hintText: '搜索标题、文件名',
          prefixIcon: const Icon(Icons.search, size: 19),
          suffixIcon:
              _searchController.text.isEmpty
                  ? IconButton(
                    tooltip: '搜索',
                    onPressed: _loading ? null : _applyQuery,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                  )
                  : IconButton(
                    tooltip: '清除搜索',
                    onPressed: _loading ? null : _clearSearch,
                    icon: const Icon(Icons.clear, size: 18),
                  ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colors.primary, width: 1.4),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  Widget _buildAccountMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 刷新、媒体库排序和应用设置收进用户菜单，顶部只保留搜索和用户两个主要入口。
    return SizedBox.square(
      dimension: 42,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.82),
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: PopupMenuButton<String>(
          tooltip: '账号',
          padding: EdgeInsets.zero,
          color: colors.surface,
          surfaceTintColor: Colors.transparent,
          icon: const Icon(Icons.person_outline, size: 20),
          onSelected: (value) {
            if (value == 'refresh') {
              _loadItems(reset: true);
            } else if (value == 'order') {
              _openOrderDialog();
            } else if (value == 'settings') {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
            } else if (value == 'logout') {
              _logout();
            }
          },
          itemBuilder:
              (_) => [
                PopupMenuItem(
                  enabled: false,
                  child: Text(EmbyPcService.instance.currentUserName),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'refresh',
                  enabled: !_loading,
                  child: const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.refresh),
                    title: Text('刷新'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'order',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.swap_vert),
                    title: Text('调整媒体库顺序'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'settings',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.settings_outlined),
                    title: Text('应用设置'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'logout', child: Text('退出登录')),
              ],
        ),
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: _sidebarCollapsed ? 64 : 248,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // 侧栏保留一层极轻的主题色，让导航与内容画布自然分区。
          color: colors.surfaceContainerLow,
          border: Border(
            right: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  _sidebarCollapsed ? 8 : 10,
                  16,
                  _sidebarCollapsed ? 8 : 10,
                  8,
                ),
                children: [
                  if (!_sidebarCollapsed) const _SidebarSectionTitle('媒体库'),
                  ..._libraries.map(
                    (library) => _SidebarButton(
                      icon: Icons.video_library_outlined,
                      title: library.name,
                      count: _libraryCounts[library.id],
                      active: _view == 'library' && library.id == _activeId,
                      collapsed: _sidebarCollapsed,
                      onPressed: () => _selectLibrary(library.id),
                    ),
                  ),
                  Divider(height: _sidebarCollapsed ? 18 : 28),
                  if (!_sidebarCollapsed) const _SidebarSectionTitle('我喜欢的'),
                  _SidebarButton(
                    icon: Icons.movie_outlined,
                    title: '影片',
                    count: _favoriteMovieCount,
                    active: _view == 'favorite-movies',
                    loading: _favoriteMovieLoading,
                    collapsed: _sidebarCollapsed,
                    onPressed: () => _selectFavorites('favorite-movies'),
                  ),
                  _SidebarButton(
                    icon: Icons.person_outline,
                    title: '演员',
                    count: _favoritePeopleCount,
                    active: _view == 'favorite-people',
                    loading: _favoritePeopleLoading,
                    collapsed: _sidebarCollapsed,
                    onPressed: () => _selectFavorites('favorite-people'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Align(
                alignment:
                    _sidebarCollapsed
                        ? Alignment.center
                        : Alignment.centerRight,
                child: IconButton(
                  tooltip: _sidebarCollapsed ? '展开侧栏' : '收起侧栏',
                  onPressed:
                      () => setState(
                        () => _sidebarCollapsed = !_sidebarCollapsed,
                      ),
                  icon: Icon(
                    _sidebarCollapsed
                        ? Icons.keyboard_double_arrow_right
                        : Icons.keyboard_double_arrow_left,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Column(
        children: [
          _buildWorkspaceHeader(context, compact: compact),
          _buildToolbar(context),
          if (_error.isNotEmpty)
            MaterialBanner(
              content: Text(_error),
              actions: [
                TextButton(
                  onPressed: () => _loadItems(reset: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          Expanded(
            child:
                _loading && _items.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _items.isEmpty
                    ? const _EmptyState()
                    : CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        if (_featureItem case final item?)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                26,
                                14,
                                26,
                                10,
                              ),
                              child: EmbyPcFeatureBanner(
                                item: item,
                                onOpen: () => _openItem(item),
                                onPlay: () => _playItem(item),
                              ),
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              26,
                              _featureItem == null ? 18 : 14,
                              26,
                              12,
                            ),
                            child: Text(
                              _featureItem == null ? '全部媒体' : '媒体库',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(26, 0, 26, 30),
                          sliver: SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent:
                                      _imageStyle == 'backdrop' ? 320 : 196,
                                  crossAxisSpacing: 20,
                                  mainAxisSpacing: 22,
                                  childAspectRatio:
                                      _imageStyle == 'backdrop' ? 1.40 : 0.56,
                                ),
                            itemCount: _items.length,
                            itemBuilder: (context, index) {
                              final item = _items[index];
                              return EmbyPcMediaTile(
                                item: item,
                                imageStyle: _imageStyle,
                                favoriteBusy: _favoriteBusyIds.contains(
                                  item.id,
                                ),
                                onOpen: () => _openItem(item),
                                onPlay:
                                    _view == 'favorite-people'
                                        ? null
                                        : () => _playItem(item),
                                onFavorite: () => _toggleFavorite(item),
                              );
                            },
                          ),
                        ),
                        if (_loadingMore)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.only(bottom: 24),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                      ],
                    ),
          ),
        ],
      ),
    );
  }

  // 优先展示可继续播放的真实 Backdrop，其次选择当前结果中评分最高的条目。
  EmbyPcItem? get _featureItem {
    if (_view == 'favorite-people') return null;
    final candidates = _items.where((item) => item.hasBackdropImage).toList();
    if (candidates.isEmpty) return null;
    for (final item in candidates) {
      if (item.playbackPositionTicks > 0 && !item.played) return item;
    }
    candidates.sort(
      (a, b) => (b.communityRating ?? 0).compareTo(a.communityRating ?? 0),
    );
    return candidates.first;
  }

  Widget _buildWorkspaceHeader(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLowest,
      child: Container(
        constraints: const BoxConstraints(minHeight: 76),
        padding: const EdgeInsets.fromLTRB(26, 16, 26, 8),
        child: Row(
          children: [
            if (compact) ...[
              _buildCompactLibraryMenu(),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      _pageTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontSize: 34, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _loading && _items.isEmpty ? '加载中' : '$_total 项',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _buildSearchField(compact ? 230 : 340),
            const SizedBox(width: 12),
            _buildAccountMenu(context),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactLibraryMenu() => PopupMenuButton<String>(
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
    itemBuilder:
        (_) => [
          ..._libraries.map(
            (library) =>
                PopupMenuItem(value: library.id, child: Text(library.name)),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'favorite-movies', child: Text('喜欢的影片')),
          const PopupMenuItem(value: 'favorite-people', child: Text('喜欢的演员')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'order', child: Text('调整媒体库顺序')),
        ],
  );

  Widget _buildToolbar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLowest,
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.fromLTRB(26, 4, 26, 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
        ),
        child: Row(
          children: [
            _buildFilterMenu(context),
            const SizedBox(width: 8),
            _buildSortMenu(context),
            const Spacer(),
            _buildLayoutControl(context),
          ],
        ),
      ),
    );
  }

  int get _activeFilterCount =>
      [
        _itemType,
        _statusFilter,
        _markFilter,
        _videoType,
        _yearController.text.trim(),
      ].where((value) => value.isNotEmpty).length;

  Widget _buildFilterMenu(BuildContext context) {
    const itemTypes = {
      '': '全部类型',
      'Movie': '电影',
      'Series': '剧集',
      'Video': '视频',
    };
    const statuses = {
      '': '全部状态',
      'IsUnplayed': '未观看',
      'IsPlayed': '已观看',
      'IsResumable': '可继续',
    };
    const videoTypes = {
      '': '全部视频',
      'videofile': '视频文件',
      'dvd': 'DVD',
      'bluray': '蓝光',
      'iso': 'ISO',
    };
    final availableWidth = MediaQuery.sizeOf(context).width - 24;
    final panelWidth = availableWidth > 420 ? 420.0 : availableWidth;
    // 菜单内容左右各保留 14 像素内边距，选项宽度直接使用剩余空间计算。
    final contentWidth = panelWidth - 28;
    final showAdvancedFilters =
        _view != 'favorite-movies' && _view != 'favorite-people';

    // 多组低频筛选集中放入弹出面板，选中后仍按原逻辑立即刷新列表。
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surface,
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        maximumSize: WidgetStatePropertyAll(Size(panelWidth, 560)),
      ),
      menuChildren: [
        SizedBox(
          width: panelWidth,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildQueryGroup(
                    title: '类型',
                    options: itemTypes,
                    selected: _itemType,
                    availableWidth: contentWidth,
                    onSelected: (value) {
                      if (value == _itemType) return;
                      setState(() => _itemType = value);
                      _applyQuery();
                    },
                  ),
                  if (showAdvancedFilters) ...[
                    _buildQueryGroup(
                      title: '播放状态',
                      options: statuses,
                      selected: _statusFilter,
                      availableWidth: contentWidth,
                      onSelected: (value) {
                        if (value == _statusFilter) return;
                        setState(() => _statusFilter = value);
                        _applyQuery();
                      },
                    ),
                  ],
                  const Text(
                    '发行年份',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 160,
                      child: TextField(
                        controller: _yearController,
                        enabled: !_loading,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _applyQuery(),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '年份',
                          suffixIcon: IconButton(
                            tooltip: '应用年份',
                            onPressed: _loading ? null : _applyQuery,
                            icon: const Icon(Icons.check, size: 18),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      builder:
          (context, controller, child) => _buildQueryPill(
            label: _activeFilterCount == 0 ? '筛选' : '筛选 $_activeFilterCount',
            icon: Icons.filter_list,
            active: _activeFilterCount > 0,
            onPressed:
                _loading
                    ? null
                    : () =>
                        controller.isOpen
                            ? controller.close()
                            : controller.open(),
          ),
    );
  }

  Widget _buildSortMenu(BuildContext context) {
    const sortOptions = {
      'CommunityRating': '评分',
      'Height': '分辨率',
      'DateCreated': '加入日期',
      'PremiereDate': '发行日期',
      'DatePlayed': '播放日期',
      'Runtime': '播放时长',
      'SortName': '文件名',
    };
    const orderOptions = {'Descending': '降序', 'Ascending': '升序'};
    final availableWidth = MediaQuery.sizeOf(context).width - 24;
    final panelWidth = availableWidth > 460 ? 460.0 : availableWidth;
    // 菜单内容左右各保留 14 像素内边距，选项宽度直接使用剩余空间计算。
    final contentWidth = panelWidth - 28;

    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surface,
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        maximumSize: WidgetStatePropertyAll(Size(panelWidth, 520)),
      ),
      menuChildren: [
        SizedBox(
          width: panelWidth,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildQueryGroup(
                  title: '排序字段',
                  options: sortOptions,
                  selected: _sortBy,
                  availableWidth: contentWidth,
                  columns: panelWidth >= 400 ? 3 : 2,
                  onSelected: (value) {
                    if (value == _sortBy) return;
                    setState(() => _sortBy = value);
                    _applyQuery();
                  },
                ),
                _buildQueryGroup(
                  title: '顺序',
                  options: orderOptions,
                  selected: _sortOrder,
                  availableWidth: contentWidth,
                  onSelected: (value) {
                    if (value == _sortOrder) return;
                    setState(() => _sortOrder = value);
                    _applyQuery();
                  },
                ),
              ],
            ),
          ),
        ),
      ],
      builder:
          (context, controller, child) => _buildQueryPill(
            label: '排序',
            icon: Icons.swap_vert,
            onPressed:
                _loading
                    ? null
                    : () =>
                        controller.isOpen
                            ? controller.close()
                            : controller.open(),
          ),
    );
  }

  Widget _buildLayoutControl(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SegmentedButton<String>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: 'backdrop',
          icon: Tooltip(message: '背景图布局', child: Icon(Icons.view_day_outlined)),
          label: Text('背景图'),
        ),
        ButtonSegment(
          value: 'poster',
          icon: Tooltip(
            message: '海报布局',
            child: Icon(Icons.view_agenda_outlined),
          ),
          label: Text('海报'),
        ),
      ],
      selected: {_imageStyle},
      onSelectionChanged:
          _loading ? null : (selection) => _updateImageStyle(selection.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        // 布局选中态与侧栏、筛选项统一使用用户设置的主题色。
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.onPrimary
              : colors.onSurface,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.primary
              : Colors.transparent,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.outlineVariant,
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }

  Future<void> _updateImageStyle(String value) async {
    if (value == _imageStyle) return;
    setState(() => _imageStyle = value);
    await EmbyPcService.instance.saveListPreferences(
      sortBy: _sortBy,
      sortOrder: _sortOrder,
      imageStyle: _imageStyle,
    );
  }

  Widget _buildQueryGroup({
    required String title,
    required Map<String, String> options,
    required String selected,
    required double availableWidth,
    required ValueChanged<String> onSelected,
    int columns = 2,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        _buildQueryOptionGrid(
          options: options,
          selected: selected,
          availableWidth: availableWidth,
          onSelected: onSelected,
          columns: columns,
        ),
      ],
    ),
  );

  Widget _buildQueryOptionGrid({
    required Map<String, String> options,
    required String selected,
    required double availableWidth,
    required ValueChanged<String> onSelected,
    int columns = 2,
  }) {
    const spacing = 8.0;
    // 避免在 MenuAnchor 的 IntrinsicWidth 测量期间使用 LayoutBuilder。
    final itemWidth = (availableWidth - spacing * (columns - 1)) / columns;
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children:
          options.entries.map((entry) {
            final active = entry.key == selected;
            return SizedBox(
              width: itemWidth,
              child: OutlinedButton(
                onPressed: _loading ? null : () => onSelected(entry.key),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  alignment: Alignment.centerLeft,
                  foregroundColor: active ? colors.primary : colors.onSurface,
                  backgroundColor:
                      active ? colors.primary.withValues(alpha: 0.12) : null,
                  side: BorderSide(
                    color: active ? colors.primary : colors.outlineVariant,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.check, size: 16),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
    );
  }

  Widget _buildQueryPill({
    required String label,
    required IconData icon,
    bool active = false,
    required VoidCallback? onPressed,
  }) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: active ? colors.primary : colors.onSurface,
        backgroundColor:
            active ? colors.primary.withValues(alpha: 0.10) : colors.surface,
        side: BorderSide(
          color: active ? colors.primary : colors.outlineVariant,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      icon: Icon(icon, size: 17),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          const Icon(Icons.keyboard_arrow_down, size: 17),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final int? count;
  final bool active;
  final bool loading;
  final bool collapsed;
  final VoidCallback onPressed;

  const _SidebarButton({
    required this.icon,
    required this.title,
    required this.count,
    required this.active,
    this.loading = false,
    this.collapsed = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final button = Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Stack(
        children: [
          Material(
            color:
                active
                    ? colors.primary.withValues(alpha: 0.11)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment:
                      collapsed
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                  children: [
                    SizedBox(width: collapsed ? 0 : 14),
                    Icon(
                      icon,
                      size: 20,
                      color: active ? colors.primary : colors.onSurfaceVariant,
                    ),
                    if (!collapsed) ...[
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // 侧栏文字固定使用微软雅黑 UI，避免中英文混用不同字体。
                            fontFamily: 'Microsoft YaHei UI',
                            fontSize: 14,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (loading)
                        const SizedBox.square(
                          dimension: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Container(
                          constraints: const BoxConstraints(minWidth: 24),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.onSurface.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            count == null ? '-' : '$count',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontFamily: 'Microsoft YaHei UI',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      const SizedBox(width: 11),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (active)
            Positioned(
              left: 0,
              top: 9,
              bottom: 9,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
    return collapsed ? Tooltip(message: title, child: button) : button;
  }
}

class _SidebarSectionTitle extends StatelessWidget {
  final String title;

  const _SidebarSectionTitle(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
    child: Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFamily: 'Microsoft YaHei UI',
        fontSize: 12,
        // 小字号使用中等字重，避免微软雅黑 UI 的笔画显得拥挤。
        fontWeight: FontWeight.w500,
      ),
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
        child:
            _libraries.isEmpty
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
                  itemBuilder:
                      (context, index) => ListTile(
                        key: ValueKey(_libraries[index].id),
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(_libraries[index].name),
                        trailing: const Icon(Icons.drag_handle),
                      ),
                ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _libraries),
        child: const Text('保存'),
      ),
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
        Icon(
          Icons.movie_filter_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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
