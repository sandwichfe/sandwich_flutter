import 'dart:async';

// Android 平台返回行为需要通过 foundation 中的平台标识进行区分。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/windows_title_bar.dart';
import '../settings_page.dart';
import 'emby_pc_detail_page.dart';
import 'emby_pc_item_images_dialog.dart';
import 'emby_pc_login_page.dart';
import 'emby_pc_models.dart';
import 'emby_pc_person_page.dart';
import 'emby_pc_playback.dart';
import 'emby_pc_service.dart';
import 'emby_pc_theme.dart';
import 'emby_pc_toast.dart';
import 'emby_pc_widgets.dart';
import 'emby_pc_workspace_controller.dart';

part 'emby_pc_workspace_navigation.dart';
part 'emby_pc_workspace_content.dart';
part 'emby_pc_workspace_toolbar.dart';
part 'emby_pc_workspace_part_groups.dart';
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
      if (mounted) {
        // 直接进入工作台时提前隐藏全局标题栏，避免首帧后再被顶掉 44 像素。
        if (!kIsWeb &&
            defaultTargetPlatform == TargetPlatform.windows &&
            EmbyPcService.instance.isLoggedIn) {
          WindowsTitleBar.embedded.value = true;
        }
        setState(() => _loading = false);
      }
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
          ? EmbyPcLoginPage(
              onLogin: () {
                // 登录成功即将进入工作台，先隐藏全局标题栏再切页。
                if (!kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.windows &&
                    EmbyPcService.instance.isLoggedIn) {
                  WindowsTitleBar.embedded.value = true;
                }
                setState(() {});
              },
            )
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

class _EmbyPcWorkspaceState extends State<EmbyPcWorkspace>
    with WidgetsBindingObserver {
  // 数据与查询状态由 controller 承载，页面只保留纯 UI 状态。
  final _c = EmbyPcWorkspaceController();
  // 页面级 Scaffold key 仅用于控制移动端导航抽屉的打开与关闭。
  final _workspaceScaffoldKey = GlobalKey<ScaffoldState>();
  final _searchController = TextEditingController();
  final _yearController = TextEditingController();
  // 演员筛选的搜索框独立于顶部标题搜索，二者互不影响。
  final _personController = TextEditingController();
  final _scrollController = ScrollController();
  // 每个视图记住自己的滚动位置：切库、切收藏或从详情返回后停在原处。
  final Map<String, double> _scrollOffsets = {};
  bool _sidebarCollapsed = false;
  final Set<String> _favoriteBusyIds = {};
  final Set<String> _libraryActionBusyIds = {};
  final Set<String> _mediaActionBusyIds = {};
  // 媒体库搜索沿用首页搜索的短防抖，连续输入时只执行最后一次查询。
  Timer? _searchDebounceTimer;
  Timer? _loadMoreDebounceTimer;
  // 视图切换历史：页头的后退/前进按钮复用同一份栈，避免做成装饰按钮。
  final List<_WorkspaceViewEntry> _viewHistory = [];
  int _viewHistoryIndex = -1;
  bool _restoringHistory = false;

  // 仅 Windows 使用自绘窗口按钮，其他平台保留系统窗口行为。
  bool get _usesWindowsChrome =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool get _canGoBack => _viewHistoryIndex > 0;

  bool get _canGoForward =>
      _viewHistoryIndex >= 0 && _viewHistoryIndex < _viewHistory.length - 1;

  @override
  void initState() {
    super.initState();
    // 工作台页头自带窗口按钮，隐藏全局标题栏避免出现双层顶栏。
    _setEmbeddedTitleBar(true);
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    // 数据变化统一由 controller 通知，页面只在这里同步一次重建。
    _c.addListener(_onWorkspaceChanged);
    // 头像加载失败后服务层通知一次，立即重建切回占位图标，不再重复请求。
    EmbyPcService.instance.avatarRevision.addListener(_onWorkspaceChanged);
    // 401 集中拦截：任何请求发现令牌失效都由服务层通知一次，这里统一回登录页。
    EmbyPcService.instance.unauthorizedRevision.addListener(
      _handleSessionExpired,
    );
    _initialize();
  }

  void _onWorkspaceChanged() {
    if (mounted) setState(() {});
  }

  void _handleSessionExpired() {
    if (!mounted) return;
    widget.onLogout();
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
      await _c.initialize();
      // 初始首页作为历史起点，页头后退按钮从第二次切换开始生效。
      _recordViewHistory();
    } catch (error) {
      if (!mounted) return;
      // 只有令牌被服务端判定失效才回登录页：服务层已清空会话。
      // 网络抖动、服务器没起来这类失败保留登录状态，改为展示可重试的错误页，
      // 否则首个请求失败就会把用户踢下线。
      if (!EmbyPcService.instance.isLoggedIn) {
        widget.onLogout();
        return;
      }
      _c.markInitializeFailed(
        _describeInitializeError(error),
        // 原始异常保留在详情里，便于排查但不再撑破错误页布局。
        detail: error.toString(),
      );
    }
  }

  // 原始异常带 URI 与 Windows 错误码，错误页主文案只留能指导用户行动的信息。
  String _describeInitializeError(Object error) {
    final text = error.toString();
    final target = EmbyPcService.instance.serverUrl;
    final suffix = target.isEmpty ? '' : '：$target';
    if (text.contains('超时')) return '连接服务器超时$suffix';
    if (text.contains('SocketException') || text.contains('ClientException')) {
      return '无法连接服务器$suffix';
    }
    return '加载媒体库失败$suffix';
  }

  // 以下三个筛选写入集中在这里，工具栏只负责展示选项。
  void _selectGenre(String genreId) {
    if (genreId == _c.genreFilter) return;
    setState(() => _c.genreFilter = genreId);
    unawaited(_applyQuery());
  }

  void _selectMinRating(double? rating) {
    if (rating == _c.minRating) return;
    setState(() => _c.minRating = rating);
    unawaited(_applyQuery());
  }

  void _selectPersonFilter(String personId, String personName) {
    setState(() {
      _c.personFilter = personId;
      _c.personFilterName = personName;
    });
    unawaited(_applyQuery());
  }

  void _clearPersonFilter() {
    if (_c.personFilter.isEmpty) return;
    setState(() {
      _c.personFilter = '';
      _c.personFilterName = '';
    });
    unawaited(_applyQuery());
  }

  // 演员筛选按关键词查人物，结果作为 PersonIds 候选。
  Future<void> _searchPersons() =>
      _c.searchPersons(_personController.text.trim());

  // 接近底部时加载下一页：单飞去抖，快速滚动只保留最后一次请求。
  void _onScroll() {
    if (_c.view == 'home' || _c.view == 'part-groups') return;
    // 随机播放只有当前这一批样本，继续翻页会变成再抽一批。
    if (_c.randomMode) return;
    if (_c.loading || _c.loadingMore || _c.refreshing) return;
    if (_scrollController.position.extentAfter > 700) return;
    _loadMoreDebounceTimer?.cancel();
    _loadMoreDebounceTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || _c.loading || _c.loadingMore || _c.refreshing) return;
      _syncQueryInput();
      _c.loadItems(reset: false);
    });
  }

  // 视图键只区分内容来源，筛选条件变化仍视为同一视图。
  String get _scrollKey => '${_c.view}:${_c.activeId}';

  // 切换视图前记录当前位置，返回该视图时再恢复。
  void _rememberScrollOffset() {
    if (_scrollController.hasClients) {
      _scrollOffsets[_scrollKey] = _scrollController.offset;
    }
  }

  void _restoreScrollOffset() {
    final target = _scrollOffsets[_scrollKey] ?? 0;
    // 新列表要到下一帧才有尺寸，恢复到有效滚动范围内避免越界。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      _scrollController.jumpTo(
        target
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台刷新首页，后台扫描新增的内容不必重进应用才可见。
    if (state == AppLifecycleState.resumed) {
      unawaited(_c.refreshHomeOnResume());
    }
  }

  // 搜索词与年份由输入框持有，查询前统一同步到 controller。
  void _syncQueryInput() {
    _c.searchTerm = _searchController.text;
    _c.productionYear = int.tryParse(_yearController.text.trim());
  }

  // ---- 视图历史：页头后退/前进按钮的线性历史 ----

  void _recordViewHistory() {
    if (_restoringHistory) return;
    final entry = _WorkspaceViewEntry(_c.view, _c.activeId);
    if (_viewHistoryIndex >= 0 && _viewHistoryIndex < _viewHistory.length) {
      final current = _viewHistory[_viewHistoryIndex];
      if (current.view == entry.view && current.activeId == entry.activeId) {
        return;
      }
    }
    // 从中间位置切走时丢弃“前进”分支，保持历史线性。
    if (_viewHistoryIndex + 1 < _viewHistory.length) {
      _viewHistory.removeRange(_viewHistoryIndex + 1, _viewHistory.length);
    }
    _viewHistory.add(entry);
    _viewHistoryIndex = _viewHistory.length - 1;
  }

  Future<void> _goBackView() async {
    if (!_canGoBack) return;
    await _restoreViewHistory(_viewHistoryIndex - 1);
  }

  Future<void> _goForwardView() async {
    if (!_canGoForward) return;
    await _restoreViewHistory(_viewHistoryIndex + 1);
  }

  Future<void> _restoreViewHistory(int index) async {
    if (index < 0 || index >= _viewHistory.length) return;
    final entry = _viewHistory[index];
    _viewHistoryIndex = index;
    // 恢复历史时不再写入栈，否则后退会变成新增记录。
    _restoringHistory = true;
    try {
      switch (entry.view) {
        case 'home':
          await _selectHome();
        case 'library':
          await _selectLibrary(entry.activeId);
        case 'latest':
          await _selectLatest();
        case 'people':
          await _selectPeople();
        case 'part-groups':
          await _selectPartGroups();
        case 'watch-history':
          await _selectWatchHistory();
        case 'favorite-movies':
        case 'favorite-people':
          await _selectFavorites(entry.view);
      }
    } finally {
      _restoringHistory = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _selectHome() async {
    if (_c.view == 'home') return;
    _rememberScrollOffset();
    // 切换首页时使正在进行的媒体库分页请求失效，避免旧结果覆盖当前状态。
    _c.queryVersion++;
    setState(() {
      _c.view = 'home';
      _c.activeId = '';
      _c.clearItems();
      _resetQueryControllers();
    });
    _recordViewHistory();
    await _c.loadHome();
    _restoreScrollOffset();
  }

  Future<void> _selectLibrary(String id) async {
    if (id.isEmpty || (_c.view == 'library' && id == _c.activeId)) return;
    _rememberScrollOffset();
    setState(() {
      _c.view = 'library';
      _c.activeId = id;
      // 切库必须清空旧列表，避免上一个媒体库的内容短暂显示在新标题下。
      _c.clearItems();
      _resetQueryControllers();
      _restoreMediaSort();
    });
    _recordViewHistory();
    await _c.loadItems(reset: true);
    _restoreScrollOffset();
  }

  Future<void> _selectFavorites(String view) async {
    if (_c.view == view) return;
    _rememberScrollOffset();
    setState(() {
      _c.view = view;
      _c.activeId = '';
      _c.clearItems();
      _resetQueryControllers();
      // 收藏演员与演员列表共用人物排序，避免继承影片浏览时的排序字段。
      if (view == 'favorite-people') {
        _c.sortBy = 'SortName';
        _c.sortOrder = 'Ascending';
      } else {
        _restoreMediaSort();
      }
    });
    _recordViewHistory();
    await _c.loadItems(reset: true);
    _restoreScrollOffset();
  }

  // 首页“最新入库”分区展开为完整列表，按加入日期倒序。
  Future<void> _selectLatest() async {
    if (_c.view == 'latest') return;
    _rememberScrollOffset();
    setState(() {
      _c.view = 'latest';
      _c.activeId = '';
      _c.clearItems();
      _resetQueryControllers();
      _c.sortBy = 'DateCreated';
      _c.sortOrder = 'Descending';
    });
    _recordViewHistory();
    await _c.loadItems(reset: true);
    _restoreScrollOffset();
  }

  Future<void> _selectPeople() async {
    if (_c.view == 'people') return;
    _rememberScrollOffset();
    setState(() {
      _c.view = 'people';
      _c.activeId = '';
      _c.clearItems();
      _resetQueryControllers();
      // 人物按名称展示，避免沿用影片默认的上映日期排序。
      _c.sortBy = 'SortName';
      _c.sortOrder = 'Ascending';
    });
    _recordViewHistory();
    await _c.loadItems(reset: true);
    _restoreScrollOffset();
  }

  // 分片影片是只读核对视图，列表与查询都由视图自己维护，这里只切换视图。
  Future<void> _selectPartGroups() async {
    if (_c.view == 'part-groups') return;
    _rememberScrollOffset();
    // 让媒体库/收藏列表在途的分页请求失效，避免旧结果写回列表状态。
    _c.queryVersion++;
    setState(() {
      _c.view = 'part-groups';
      _c.activeId = '';
      _c.clearItems();
      _resetQueryControllers();
    });
    _recordViewHistory();
  }

  // 观看历史：所有播放过的条目，按最近播放时间倒序。
  Future<void> _selectWatchHistory() async {
    if (_c.view == 'watch-history') return;
    _rememberScrollOffset();
    setState(() {
      _c.view = 'watch-history';
      _c.activeId = '';
      _c.clearItems();
      _resetQueryControllers();
      // 最近播放时间倒序是观看历史的默认顺序。
      _c.sortBy = 'DatePlayed';
      _c.sortOrder = 'Descending';
    });
    _recordViewHistory();
    await _c.loadItems(reset: true);
    _restoreScrollOffset();
  }

  // 空列表一键恢复：清空搜索、年份、演员与全部筛选后重新查询。
  Future<void> _clearAllFilters() async {
    setState(_resetQueryControllers);
    await _applyQuery();
  }

  // 演员专用的排序字段（年龄/罩杯）在影片列表里没有对应列，
  // 切回影片视图时恢复默认排序，避免列表静默地按名称排列。
  void _restoreMediaSort() {
    if (_c.sortBy == 'Age' || _c.sortBy == 'CupSize') {
      _c.sortBy = 'PremiereDate';
      _c.sortOrder = 'Descending';
    }
  }

  void _resetQueryControllers() {
    _searchDebounceTimer?.cancel();
    _searchController.clear();
    _yearController.clear();
    _personController.clear();
    // 查询条件统一由 controller 清理，避免遗漏新增筛选项。
    _c.resetFilters();
  }

  Future<void> _applyQuery() async {
    _searchDebounceTimer?.cancel();
    _syncQueryInput();
    await _c.applyQuery();
  }

  void _scheduleSearch(String value) {
    _searchDebounceTimer?.cancel();
    // 输入变化时立即让旧请求失效，避免旧关键词结果覆盖新输入。
    _c.queryVersion++;
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
    _c.queryVersion++;
    unawaited(_applyQuery());
  }

  Future<void> _clearSearch() async {
    if (_searchController.text.isEmpty) return;
    _c.queryVersion++;
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
      // 列表、首页快照与侧栏计数由 controller 一次性同步。
      _c.applyFavoriteResult(item, value);
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
      // 标记已看只改用户数据，成功后立即同步角标与续播位置，不必重拉列表。
      if (action == EmbyPcMediaAction.togglePlayed) {
        final value = await EmbyPcService.instance.setPlayed(
          item.id,
          !item.played,
        );
        if (!mounted) return false;
        _c.applyPlayedResult(item, value);
        _showWorkspaceMessage(value ? '已标记为已看' : '已标记为未看');
        return true;
      }

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
    if (_c.view == 'home') {
      await _c.loadHome(force: true);
    } else {
      _syncQueryInput();
      await _c.loadItems(reset: true);
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
      if (changed == true && mounted) await _reloadLibraries();
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
      EmbyPcToast.show(context, error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _libraryActionBusyIds.remove(libraryId));
    }
  }

  // 图像、媒体库增删改都会改变侧边栏结构，统一重新拉取 Views。
  // order 为空时沿用当前内存顺序；外部改过排序号时传入已保存的顺序。
  Future<void> _reloadLibraries({List<String>? order}) async {
    try {
      final libraries = await EmbyPcService.instance.getLibraries();
      if (!mounted) return;
      final currentOrder =
          order ?? _c.libraries.map((item) => item.id).toList();
      setState(
        () => _c.libraries = _c.applyLibraryOrder(libraries, currentOrder),
      );
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

  Future<void> _logout() async {
    await EmbyPcService.instance.logout();
    if (!mounted) return;
    // 回到登录页后由全局标题栏接管窗口按钮。
    WindowsTitleBar.embedded.value = false;
    widget.onLogout();
  }

  void _openItem(EmbyPcItem item) {
    // 人物接口通常返回 Person 类型；视图条件同时兼容缺失类型字段的服务端响应。
    if (item.type == 'Person' ||
        _c.view == 'favorite-people' ||
        _c.view == 'people') {
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
    Navigator.of(context).push(
      embyPcFadeRoute(
        context,
        (_) => EmbyPcDetailPage(item: item, onMediaAction: _handleMediaAction),
      ),
    );
  }

  Future<void> _playItem(EmbyPcItem item) async {
    // 播放返回后会刷新列表，通过统一的播放上下文起播并记住当前位置。
    _rememberScrollOffset();
    // 播放页没有自绘窗口按钮，播放期间交回全局标题栏。
    if (_usesWindowsChrome) WindowsTitleBar.embedded.value = false;
    bool played;
    try {
      played = await openEmbyPcPlayer(
        context,
        EmbyPcPlaybackRequest(
          item: item,
          startPositionTicks: item.playbackPositionTicks,
        ),
      );
    } finally {
      if (mounted && _usesWindowsChrome) {
        WindowsTitleBar.embedded.value = true;
      }
    }
    // 直接播放返回后刷新当前工作台视图，避免继续显示旧的播放进度。
    if (!played || !mounted) return;
    await _reloadMediaAfterChange();
    _restoreScrollOffset();
  }

  // 延迟到帧结束再切换全局标题栏，避免在 build/dispose 阶段通知祖先重建。
  void _setEmbeddedTitleBar(bool value) {
    if (!_usesWindowsChrome) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WindowsTitleBar.embedded.value = value;
    });
  }

  @override
  void dispose() {
    // 退出工作台（例如退出登录）时恢复全局标题栏。
    _setEmbeddedTitleBar(false);
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onWorkspaceChanged);
    _c.dispose();
    EmbyPcService.instance.avatarRevision.removeListener(_onWorkspaceChanged);
    EmbyPcService.instance.unauthorizedRevision.removeListener(
      _handleSessionExpired,
    );
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _yearController.dispose();
    _personController.dispose();
    _scrollController.dispose();
    _loadMoreDebounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 工作台整体套一层独立的影院主题，避免改动全局设置页的明暗与圆角。
    return Theme(
      data: EmbyPcSkin.themeDataOf(context),
      child: Builder(
        builder: (context) => LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 820;
            final mobileWorkspace = _usesMobileWorkspaceLayout(
              constraints.maxWidth,
            );
            return Scaffold(
              key: _workspaceScaffoldKey,
              drawer: mobileWorkspace
                  ? _EmbyPcWorkspaceNavigation(
                      this,
                    )._buildMobileNavigationDrawer(context)
                  : null,
              body: _c.error.isNotEmpty && _c.libraries.isEmpty
                  ? _WorkspaceError(
                      message: _c.error,
                      detail: _c.errorDetail,
                      onRetry: _initialize,
                      // 清会话后回到登录页，用户可重新填写服务器地址再登录。
                      onLogout: _logout,
                    )
                  : EmbyPcBackdrop(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!compact)
                            _EmbyPcWorkspaceNavigation(
                              this,
                            )._buildSidebar(context),
                          Expanded(
                            child: _EmbyPcWorkspaceContent(
                              this,
                            )._buildContent(context, compact: compact),
                          ),
                        ],
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }
}

// 视图历史条目：视图类型 + 媒体库 ID，可完整还原一次视图切换。
class _WorkspaceViewEntry {
  final String view;
  final String activeId;

  const _WorkspaceViewEntry(this.view, this.activeId);
}
