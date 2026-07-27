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
  final _layoutMenuController = MenuController();
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
  bool _searchExpanded = false;
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

  // 搜索入口默认保持收起，展开后再将焦点交给输入框。
  void _expandSearch() {
    if (_loading || _searchExpanded) return;
    setState(() => _searchExpanded = true);
  }

  void _collapseSearch() {
    if (!_searchExpanded) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _searchExpanded = false);
  }

  Future<void> _clearSearch() async {
    if (_searchController.text.isEmpty) return;
    setState(_searchController.clear);
    await _applyQuery();
  }

  // 重置查询时恢复默认排序，但保留用户当前选择的图片布局。
  Future<void> _resetQuery() async {
    setState(() {
      _resetQueryControllers();
      _sortBy = 'PremiereDate';
      _sortOrder = 'Descending';
    });
    await _applyQuery();
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
            title: compact && _searchExpanded
                ? _buildExpandedSearchField()
                : Text(_pageTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
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
              if (!compact || !_searchExpanded) _buildToolbarSearchAction(context),
              _buildAccountMenu(context),
              const SizedBox(width: 10),
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

  Widget _buildToolbarSearchAction(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_searchExpanded) {
      final searchWidth = (MediaQuery.sizeOf(context).width * 0.36).clamp(320.0, 520.0).toDouble();
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: _buildExpandedSearchField(width: searchWidth),
      );
    }

    final hasKeyword = _searchController.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: IconButton(
        tooltip: '搜索媒体',
        onPressed: _loading ? null : _expandSearch,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(44),
          foregroundColor: hasKeyword ? colors.primary : colors.onSurfaceVariant,
          backgroundColor: hasKeyword ? colors.primaryContainer.withValues(alpha: 0.45) : null,
          side: BorderSide(color: hasKeyword ? colors.primary : colors.outlineVariant),
        ),
        icon: const Icon(Icons.search, size: 20),
      ),
    );
  }

  Widget _buildExpandedSearchField({double? width}) {
    final colors = Theme.of(context).colorScheme;
    final field = SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              enabled: !_loading,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _applyQuery(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索标题、文件名',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: _loading ? null : _clearSearch,
                        icon: const Icon(Icons.clear, size: 18),
                      ),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(999),
                    bottomLeft: Radius.circular(999),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.outlineVariant),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(999),
                    bottomLeft: Radius.circular(999),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(999),
                    bottomLeft: Radius.circular(999),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 86,
            height: 40,
            child: FilledButton.icon(
              onPressed: _loading ? null : _applyQuery,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.only(
                    topRight: Radius.circular(999),
                    bottomRight: Radius.circular(999),
                  ),
                ),
              ),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('搜索'),
            ),
          ),
        ],
      ),
    );

    // 点击搜索区域外时自动收起，已提交的关键词仍会保留并高亮搜索入口。
    return TapRegion(
      onTapOutside: (_) => _collapseSearch(),
      child: width == null ? field : SizedBox(width: width, child: field),
    );
  }

  Widget _buildAccountMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 刷新与媒体库排序收进用户菜单，顶部只保留搜索和用户两个主要入口。
    return SizedBox.square(
      dimension: 44,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: PopupMenuButton<String>(
          tooltip: '账号',
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.person_outline, size: 20),
          onSelected: (value) {
            if (value == 'refresh') {
              _loadItems(reset: true);
            } else if (value == 'order') {
              _openOrderDialog();
            } else if (value == 'logout') {
              _logout();
            }
          },
          itemBuilder: (_) => [
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
            const PopupMenuItem(value: 'logout', child: Text('退出登录')),
          ],
        ),
      ),
    );
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
                      child: Text(
                        '媒体库',
                        // 侧栏分组标题使用清晰的 Windows 中文 UI 字体。
                        style: TextStyle(
                          fontFamily: 'Microsoft YaHei UI',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                      child: Text(
                        '我喜欢的',
                        // 与媒体库分组保持一致的字体和字重。
                        style: TextStyle(
                          fontFamily: 'Microsoft YaHei UI',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
          child: _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
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
    final controls = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _buildFilterMenu(context),
        _buildSortMenu(context),
        _buildLayoutMenu(context),
        _buildQueryPill(
          label: '重置',
          onPressed: _loading ? null : _resetQuery,
        ),
      ],
    );
    final total = Text(
      _mediaTotalText,
      textAlign: TextAlign.right,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 13,
      ),
    );

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        // 窄屏时加载信息独占一行，避免与查询按钮相互挤压。
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  controls,
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: total),
                ],
              )
            : Row(
                children: [
                  Expanded(child: controls),
                  const SizedBox(width: 12),
                  total,
                ],
              ),
      ),
    );
  }

  String get _mediaTotalText {
    if (_loading && _items.isEmpty) return '加载中';
    final loadingSuffix = _loadingMore ? '，加载中...' : '';
    if (_total > 0) return '已加载 ${_items.length} / $_total 项$loadingSuffix';
    return '共 ${_items.length} 项$loadingSuffix';
  }

  String get _filterButtonText {
    const itemTypes = {'Movie': '电影', 'Series': '剧集', 'Video': '视频'};
    const statuses = {'IsUnplayed': '未观看', 'IsPlayed': '已观看', 'IsResumable': '可继续'};
    const marks = {'IsFavorite': '收藏', 'Likes': '喜欢', 'Dislikes': '不喜欢'};
    const videoTypes = {'videofile': '视频文件', 'dvd': 'DVD', 'bluray': '蓝光', 'iso': 'ISO'};
    final selected = <String?>[
      itemTypes[_itemType],
      statuses[_statusFilter],
      marks[_markFilter],
      videoTypes[_videoType],
      if (_yearController.text.trim().isNotEmpty) _yearController.text.trim(),
    ].whereType<String>().toList();
    return selected.isEmpty ? '全部筛选' : selected.join(' / ');
  }

  Widget _buildFilterMenu(BuildContext context) {
    const itemTypes = {'': '全部类型', 'Movie': '电影', 'Series': '剧集', 'Video': '视频'};
    const statuses = {
      '': '全部状态',
      'IsUnplayed': '未观看',
      'IsPlayed': '已观看',
      'IsResumable': '可继续',
    };
    const marks = {'': '全部偏好', 'IsFavorite': '收藏', 'Likes': '喜欢', 'Dislikes': '不喜欢'};
    const videoTypes = {
      '': '全部视频',
      'videofile': '视频文件',
      'dvd': 'DVD',
      'bluray': '蓝光',
      'iso': 'ISO',
    };
    final availableWidth = MediaQuery.sizeOf(context).width - 24;
    final panelWidth = availableWidth > 420 ? 420.0 : availableWidth;
    final showAdvancedFilters = _view != 'favorite-movies' && _view != 'favorite-people';

    // 多组低频筛选集中放入弹出面板，选中后仍按原逻辑立即刷新列表。
    return MenuAnchor(
      style: MenuStyle(
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
                      onSelected: (value) {
                        if (value == _statusFilter) return;
                        setState(() => _statusFilter = value);
                        _applyQuery();
                      },
                    ),
                    _buildQueryGroup(
                      title: '收藏偏好',
                      options: marks,
                      selected: _markFilter,
                      onSelected: (value) {
                        if (value == _markFilter) return;
                        setState(() => _markFilter = value);
                        _applyQuery();
                      },
                    ),
                    _buildQueryGroup(
                      title: '视频类型',
                      options: videoTypes,
                      selected: _videoType,
                      onSelected: (value) {
                        if (value == _videoType) return;
                        setState(() => _videoType = value);
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
      builder: (context, controller, child) => _buildQueryPill(
        label: '筛选',
        value: _filterButtonText,
        onPressed: _loading
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
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

    return MenuAnchor(
      style: MenuStyle(
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
      builder: (context, controller, child) => _buildQueryPill(
        label: '排序',
        onPressed: _loading
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Widget _buildLayoutMenu(BuildContext context) {
    const layoutOptions = {'backdrop': '背景图', 'poster': '海报'};
    final availableWidth = MediaQuery.sizeOf(context).width - 24;
    final panelWidth = availableWidth > 260 ? 260.0 : availableWidth;
    return MenuAnchor(
      controller: _layoutMenuController,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        maximumSize: WidgetStatePropertyAll(Size(panelWidth, 220)),
      ),
      menuChildren: [
        SizedBox(
          width: panelWidth,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: _buildQueryOptionGrid(
              options: layoutOptions,
              selected: _imageStyle,
              onSelected: (value) {
                if (value == _imageStyle) return;
                _layoutMenuController.close();
                setState(() => _imageStyle = value);
                _applyQuery();
              },
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => _buildQueryPill(
        label: '布局',
        onPressed: _loading
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Widget _buildQueryGroup({
    required String title,
    required Map<String, String> options,
    required String selected,
    required ValueChanged<String> onSelected,
    int columns = 2,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _buildQueryOptionGrid(
          options: options,
          selected: selected,
          onSelected: onSelected,
          columns: columns,
        ),
      ],
    ),
  );

  Widget _buildQueryOptionGrid({
    required Map<String, String> options,
    required String selected,
    required ValueChanged<String> onSelected,
    int columns = 2,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = 8.0;
      final itemWidth = (constraints.maxWidth - spacing * (columns - 1)) / columns;
      final colors = Theme.of(context).colorScheme;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: options.entries.map((entry) {
          final active = entry.key == selected;
          return SizedBox(
            width: itemWidth,
            child: OutlinedButton(
              onPressed: _loading ? null : () => onSelected(entry.key),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                alignment: Alignment.centerLeft,
                foregroundColor: active ? colors.primary : colors.onSurface,
                backgroundColor: active ? colors.primaryContainer.withValues(alpha: 0.45) : null,
                side: BorderSide(color: active ? colors.primary : colors.outlineVariant),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
    },
  );

  Widget _buildQueryPill({
    required String label,
    String? value,
    required VoidCallback? onPressed,
  }) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(112, 38),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: const StadiumBorder(),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        if (value != null) ...[
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
        if (label != '重置') ...[
          const SizedBox(width: 6),
          const Icon(Icons.keyboard_arrow_down, size: 18),
        ],
      ],
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
