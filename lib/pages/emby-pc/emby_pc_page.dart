import 'dart:async';

// Android 平台返回行为需要通过 foundation 中的平台标识进行区分。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings_page.dart';
import 'emby_pc_detail_page.dart';
import 'emby_pc_item_images_dialog.dart';
import 'emby_pc_login_page.dart';
import 'emby_pc_models.dart';
import 'emby_pc_person_page.dart';
import 'emby_pc_player_page.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';
import 'emby_pc_widgets.dart';

part 'emby_pc_workspace_navigation.dart';
part 'emby_pc_workspace_content.dart';
part 'emby_pc_workspace_toolbar.dart';
part 'emby_pc_global_search.dart';
part 'emby_pc_workspace_support.dart';

// 入口页负责先恢复桌面会话，再决定展示登录页还是媒体工作台。
class EmbyPcEntryPage extends StatefulWidget {
  const EmbyPcEntryPage({super.key});

  @override
  State<EmbyPcEntryPage> createState() => _EmbyPcEntryPageState();
}

class _EmbyPcEntryPageState extends State<EmbyPcEntryPage> {
  bool _loading = true;
  // 防止系统返回键连续触发时重复打开退出确认弹框。
  bool _exitDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    try {
      await EmbyPcService.instance.restoreSession();
    } catch (_) {
      // 本地会话读取失败时清除残留状态，确保入口页可以回到登录界面。
      await EmbyPcService.instance.logout();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleRootBack(bool didPop) async {
    if (didPop || _exitDialogOpen) return;
    _exitDialogOpen = true;
    // 根页面返回时由用户明确确认，避免误触系统返回键直接退出应用。
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出应用'),
        content: const Text('确定要退出应用吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (shouldExit == true) {
      SystemNavigator.pop();
      return;
    }
    if (mounted) _exitDialogOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    final interceptAndroidBack =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return PopScope<void>(
      // 非 Android 平台继续沿用系统默认返回行为，避免影响桌面端窗口关闭。
      canPop: !interceptAndroidBack,
      onPopInvokedWithResult: (didPop, _) {
        if (interceptAndroidBack) unawaited(_handleRootBack(didPop));
      },
      child: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : !EmbyPcService.instance.isLoggedIn
          ? EmbyPcLoginPage(onLogin: () => setState(() {}))
          : EmbyPcWorkspace(onLogout: () => setState(() {})),
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
  // 页面级 Scaffold key 仅用于控制移动端导航抽屉的打开与关闭。
  final _workspaceScaffoldKey = GlobalKey<ScaffoldState>();
  final _searchController = TextEditingController();
  final _yearController = TextEditingController();
  final _scrollController = ScrollController();
  List<EmbyPcItem> _libraries = const [];
  List<EmbyPcItem> _items = const [];
  List<EmbyPcItem> _recentlyPlayed = const [];
  Map<String, List<EmbyPcItem>> _homeLibraryItems = const {};
  final Map<String, int?> _libraryCounts = {};
  int? _favoriteMovieCount;
  int? _favoritePeopleCount;
  String _activeId = '';
  String _view = 'home';
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
  bool _homeLoading = false;
  bool _homeLoaded = false;
  bool _countsLoading = true;
  bool _favoritePeopleLoading = false;
  bool _favoriteMovieLoading = false;
  bool _sidebarCollapsed = false;
  String _error = '';
  String _homeError = '';
  int _queryVersion = 0;
  final Set<String> _favoriteBusyIds = {};
  final Set<String> _libraryActionBusyIds = {};
  final Set<String> _mediaActionBusyIds = {};
  // 媒体库搜索沿用首页搜索的短防抖，连续输入时只执行最后一次查询。
  Timer? _searchDebounceTimer;
  Timer? _loadMoreDebounceTimer;
  DateTime? _lastLoadMoreTime;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initialize();
  }

  // 移动端专用布局与桌面端分离，避免窄窗口影响 Windows 原有样式。
  bool _usesMobileWorkspaceLayout(double width) =>
      !kIsWeb &&
      width < 600 &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _openMobileNavigation() {
    _workspaceScaffoldKey.currentState?.openDrawer();
  }

  void _selectFromMobileNavigation(VoidCallback action) {
    // 先收起抽屉再切换内容，避免新页面加载状态出现在抽屉下方。
    _workspaceScaffoldKey.currentState?.closeDrawer();
    action();
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
        _imageStyle = preferences.imageStyle == 'poster'
            ? 'poster'
            : 'backdrop';
        // 工作台默认进入首页，媒体库详情仅在用户选择后再按需加载。
        _activeId = '';
        _loading = false;
      });
      _loadCounts(ordered);
      await _loadHome();
    } catch (_) {
      // 恢复的会话无法完成首次请求时视为失效，返回登录页重新连接。
      try {
        await EmbyPcService.instance.logout();
      } finally {
        if (mounted) widget.onLogout();
      }
    }
  }

  Future<void> _loadHome({bool force = false}) async {
    if (_homeLoading || (_homeLoaded && !force)) return;
    final libraries = List<EmbyPcItem>.of(_libraries);
    setState(() {
      _homeLoading = true;
      _homeError = '';
    });
    try {
      // 首页数据彼此独立，首次进入时并行获取继续观看和各媒体库前十条。
      final results = await Future.wait<EmbyPcPage>([
        EmbyPcService.instance.getResumeItems(),
        ...libraries.map(
          (library) =>
              EmbyPcService.instance.getItems(libraryId: library.id, limit: 10),
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _recentlyPlayed = results.first.items;
        _homeLibraryItems = {
          for (var index = 0; index < libraries.length; index++)
            libraries[index].id: results[index + 1].items,
        };
        _homeLoading = false;
        _homeLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _homeLoading = false;
        _homeError = error.toString();
      });
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
      final page = _view == 'people'
          // 演员列表走 Persons 专用接口，返回整个服务器可见范围内的人物。
          ? await EmbyPcService.instance.getPersons(
              startIndex: reset ? 0 : _items.length,
              searchTerm: _searchController.text,
              sortBy: _sortBy,
              sortOrder: _sortOrder,
            )
          : _view == 'recently-played'
          ? await EmbyPcService.instance.getResumeItems(
              startIndex: reset ? 0 : _items.length,
              limit: 100,
              itemType: _itemType,
              searchTerm: _searchController.text,
              productionYear: int.tryParse(_yearController.text.trim()),
              sortBy: _sortBy,
              sortOrder: _sortOrder,
            )
          : await EmbyPcService.instance.getItems(
              libraryId: _view == 'library' ? _activeId : '',
              favoriteOnly:
                  _view == 'favorite-movies' || _view == 'favorite-people',
              startIndex: reset ? 0 : _items.length,
              itemType: _view == 'favorite-people' ? 'Person' : _itemType,
              filters: _view == 'favorite-movies' || _view == 'favorite-people'
                  ? ''
                  : <String>[
                      // 非继续观看列表保留原有的状态和标记筛选。
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
    if (_view == 'home') return;
    // 正在加载时不处理滚动事件，避免创建无用的定时器
    if (_loading || _loadingMore) return;

    if (_scrollController.position.extentAfter < 700) {
      final now = DateTime.now();
      // 节流：如果距离上次加载不到 1000ms，使用防抖延迟执行
      if (_lastLoadMoreTime != null &&
          now.difference(_lastLoadMoreTime!).inMilliseconds < 1000) {
        // 防抖：取消旧定时器，延迟到节流间隔结束后执行
        _loadMoreDebounceTimer?.cancel();
        final remainingTime =
            800 - now.difference(_lastLoadMoreTime!).inMilliseconds;
        _loadMoreDebounceTimer = Timer(
          Duration(milliseconds: remainingTime + 100),
          () {
            // 定时器触发时再次检查状态，避免在加载过程中重复触发
            if (!_loading && !_loadingMore) {
              _lastLoadMoreTime = DateTime.now();
              _loadItems(reset: false);
            }
          },
        );
      } else {
        // 节流间隔已过，立即执行并记录时间
        _loadMoreDebounceTimer?.cancel();
        _lastLoadMoreTime = now;
        _loadItems(reset: false);
      }
    }
  }

  Future<void> _selectHome() async {
    if (_view == 'home') return;
    // 切换首页时使正在进行的媒体库分页请求失效，避免旧结果覆盖当前状态。
    _queryVersion++;
    setState(() {
      _view = 'home';
      _activeId = '';
      _resetQueryControllers();
    });
    await _loadHome();
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

  Future<void> _selectPeople() async {
    if (_view == 'people') return;
    setState(() {
      _view = 'people';
      _activeId = '';
      _resetQueryControllers();
      // 人物按名称展示，避免沿用影片默认的上映日期排序。
      _sortBy = 'SortName';
      _sortOrder = 'Ascending';
    });
    await _loadItems(reset: true);
  }

  Future<void> _selectRecentlyPlayed() async {
    if (_view == 'recently-played') return;
    setState(() {
      _view = 'recently-played';
      _activeId = '';
      _resetQueryControllers();
      // Resume uses Emby Web's default DatePlayed descending order.
      _sortBy = 'DatePlayed';
      _sortOrder = 'Descending';
    });
    await _loadItems(reset: true);
  }

  void _resetQueryControllers() {
    _searchDebounceTimer?.cancel();
    _searchController.clear();
    _yearController.clear();
    _itemType = '';
    _statusFilter = '';
    _markFilter = '';
    _videoType = '';
  }

  Future<void> _applyQuery() async {
    _searchDebounceTimer?.cancel();
    await EmbyPcService.instance.saveListPreferences(
      sortBy: _sortBy,
      sortOrder: _sortOrder,
      imageStyle: _imageStyle,
    );
    await _loadItems(reset: true);
  }

  void _scheduleSearch(String value) {
    _searchDebounceTimer?.cancel();
    // 输入变化时立即让旧请求失效，避免旧关键词结果覆盖新输入。
    _queryVersion++;
    setState(() {});
    if (value.trim().isEmpty) {
      unawaited(_applyQuery());
      return;
    }
    _searchDebounceTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_applyQuery()),
    );
  }

  void _submitSearch(String _) {
    // 回车提交时跳过等待，并取消尚未执行的防抖查询。
    _queryVersion++;
    unawaited(_applyQuery());
  }

  Future<void> _clearSearch() async {
    if (_searchController.text.isEmpty) return;
    _queryVersion++;
    setState(_searchController.clear);
    await _applyQuery();
  }

  Future<void> _openGlobalSearch() async {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final selected = await showGeneralDialog<EmbyPcItem>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: const Color(0x47000000),
      transitionDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
          child: Align(
            // 搜索浮层在顶部保留呼吸空间，查询前后保持位置稳定。
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 580, maxHeight: 640),
              child: const _GlobalSearchDialog(),
            ),
          ),
        ),
      ),
      transitionBuilder: (_, animation, _, child) {
        if (reduceMotion) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.025),
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );
    if (selected != null && mounted) _openItem(selected);
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
        _items = _items
            .map((entry) => entry.id == item.id ? updated : entry)
            .toList();
        // 首页横向列表持有独立快照，收藏完成后同步状态以立即刷新图标。
        _recentlyPlayed = _recentlyPlayed
            .map(
              (entry) => entry.id == item.id
                  ? entry.copyWith(isFavorite: value)
                  : entry,
            )
            .toList();
        _homeLibraryItems = {
          for (final library in _homeLibraryItems.entries)
            library.key: library.value
                .map(
                  (entry) => entry.id == item.id
                      ? entry.copyWith(isFavorite: value)
                      : entry,
                )
                .toList(),
        };
        if (!value && _view == 'favorite-movies') {
          _items = _items.where((entry) => entry.id != item.id).toList();
          _total = (_total - 1).clamp(0, 1 << 30).toInt();
        }
        if (_view == 'favorite-movies' && _favoriteMovieCount != null) {
          _favoriteMovieCount = (_favoriteMovieCount! + (value ? 1 : -1))
              .clamp(0, 1 << 30)
              .toInt();
        }
        // 从演员列表修改收藏时，同步侧栏的收藏演员数量。
        if ((_view == 'favorite-people' || _view == 'people') &&
            _favoritePeopleCount != null) {
          _favoritePeopleCount = (_favoritePeopleCount! + (value ? 1 : -1))
              .clamp(0, 1 << 30)
              .toInt();
        }
      });
    } catch (error) {
      if (mounted) {
        EmbyPcToast.show(
          context,
          error.toString(),
          type: EmbyPcToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _favoriteBusyIds.remove(item.id));
    }
  }

  Future<bool> _handleMediaAction(
    EmbyPcItem item,
    EmbyPcMediaAction action,
  ) async {
    if (_mediaActionBusyIds.contains(item.id)) return false;
    setState(() => _mediaActionBusyIds.add(item.id));
    try {
      if (action == EmbyPcMediaAction.editMetadata) {
        final metadata = await EmbyPcService.instance.getItemForEditing(
          item.id,
        );
        if (!mounted) return false;
        final changed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              _ItemMetadataDialog(itemId: item.id, item: metadata),
        );
        if (changed != true || !mounted) return false;
        _showWorkspaceMessage('元数据已保存');
        await _reloadMediaAfterChange();
        return true;
      }

      if (action == EmbyPcMediaAction.editImages) {
        final changed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => EmbyPcItemImagesDialog(item: item),
        );
        if (changed == true && mounted) await _reloadMediaAfterChange();
        return changed == true;
      }

      final response = await EmbyPcService.instance.refreshMetadata(
        item.id,
        mode: 'Default',
        replaceImages: false,
        replaceThumbnailImages: false,
      );
      if (mounted) {
        _showWorkspaceMessage(response.isEmpty ? '元数据刷新请求已提交' : response);
      }
      return false;
    } catch (error) {
      if (mounted) {
        _showWorkspaceMessage(error.toString(), type: EmbyPcToastType.error);
      }
      return false;
    } finally {
      if (mounted) setState(() => _mediaActionBusyIds.remove(item.id));
    }
  }

  Future<void> _reloadMediaAfterChange() async {
    if (_view == 'home') {
      await _loadHome(force: true);
    } else {
      await _loadItems(reset: true);
    }
  }

  void _showWorkspaceMessage(
    String message, {
    EmbyPcToastType type = EmbyPcToastType.success,
  }) {
    EmbyPcToast.show(context, message, type: type);
  }

  Future<void> _handleLibraryAction(
    EmbyPcItem library,
    _LibraryAction action,
  ) async {
    if (action == _LibraryAction.editImages) {
      final changed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => EmbyPcItemImagesDialog(item: library),
      );
      if (changed == true && mounted) await _reloadLibrariesAfterImageChange();
      return;
    }

    if (action == _LibraryAction.refreshMetadata) {
      final options = await showDialog<_MetadataRefreshOptions>(
        context: context,
        builder: (context) => _MetadataRefreshDialog(name: library.name),
      );
      if (options == null || !mounted) return;
      await _runLibraryAction(
        library.id,
        () => EmbyPcService.instance.refreshMetadata(
          library.id,
          mode: options.mode,
          replaceImages: options.replaceImages,
          replaceThumbnailImages: options.replaceThumbnailImages,
        ),
        successMessage: '元数据刷新请求已提交',
      );
      return;
    }

    await _runLibraryAction(
      library.id,
      EmbyPcService.instance.scanLibrary,
      successMessage: '媒体库扫描请求已提交',
    );
  }

  Future<void> _runLibraryAction(
    String libraryId,
    Future<String> Function() request, {
    required String successMessage,
  }) async {
    if (_libraryActionBusyIds.contains(libraryId)) return;
    setState(() => _libraryActionBusyIds.add(libraryId));
    try {
      final response = await request();
      if (!mounted) return;
      final message = response.isEmpty ? successMessage : response;
      EmbyPcToast.show(context, message, type: EmbyPcToastType.success);
    } catch (error) {
      if (!mounted) return;
      EmbyPcToast.show(
        context,
        error.toString(),
        type: EmbyPcToastType.error,
      );
    } finally {
      if (mounted) setState(() => _libraryActionBusyIds.remove(libraryId));
    }
  }

  Future<void> _reloadLibrariesAfterImageChange() async {
    try {
      final libraries = await EmbyPcService.instance.getLibraries();
      if (!mounted) return;
      final currentOrder = _libraries.map((item) => item.id).toList();
      setState(() => _libraries = _applyLibraryOrder(libraries, currentOrder));
    } catch (error) {
      if (mounted) {
        EmbyPcToast.show(
          context,
          error.toString(),
          type: EmbyPcToastType.error,
        );
      }
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
    // 人物接口通常返回 Person 类型；视图条件同时兼容缺失类型字段的服务端响应。
    if (item.type == 'Person' ||
        _view == 'favorite-people' ||
        _view == 'people') {
      Navigator.of(context).push(
        embyPcFadeRoute(
          context,
          (_) => EmbyPcPersonPage(
            personId: item.id,
            personName: item.name,
            onMediaAction: _handleMediaAction,
          ),
        ),
      );
      return;
    }
    Navigator.of(
      context,
    ).push(
      embyPcFadeRoute(
        context,
        (_) => EmbyPcDetailPage(
          item: item,
          onMediaAction: _handleMediaAction,
        ),
      ),
    );
  }

  Future<void> _playItem(EmbyPcItem item) async {
    final played = await Navigator.of(context).push<bool>(
      embyPcFadeRoute(
        context,
        (_) => EmbyPcPlayerPage(
          item: item,
          startPositionTicks: item.playbackPositionTicks,
        ),
      ),
    );
    // 直接播放返回后刷新当前工作台视图，避免继续显示旧的播放进度。
    if (played == true && mounted) await _reloadMediaAfterChange();
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _yearController.dispose();
    _scrollController.dispose();
    _loadMoreDebounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 820;
        final mobileWorkspace = _usesMobileWorkspaceLayout(
          constraints.maxWidth,
        );
        return Scaffold(
          key: _workspaceScaffoldKey,
          drawer:
              mobileWorkspace
                  ? _EmbyPcWorkspaceNavigation(
                    this,
                  )._buildMobileNavigationDrawer(context)
                  : null,
          body: _error.isNotEmpty && _libraries.isEmpty
              ? _WorkspaceError(message: _error, onRetry: _initialize)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!compact)
                      _EmbyPcWorkspaceNavigation(this)._buildSidebar(context),
                    Expanded(
                      child: _EmbyPcWorkspaceContent(
                        this,
                      )._buildContent(context, compact: compact),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
