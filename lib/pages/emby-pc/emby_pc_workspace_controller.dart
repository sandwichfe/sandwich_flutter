import 'dart:async';

import 'package:flutter/foundation.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';

// 工作台的数据与查询状态集中在这里，页面只保留渲染与交互。
// 拆分的动机：视图切换、分页和筛选共用同一份查询状态，
// 继续摊在 State 里会让工作台文件无边界地膨胀，后续也很难再加数据层。
class EmbyPcWorkspaceController extends ChangeNotifier {
  final EmbyPcService _service = EmbyPcService.instance;

  // ---- 媒体库与首页摘要 ----
  List<EmbyPcItem> libraries = const [];
  // 列表可变，分页时原地追加，避免每次滚动加载都复制整个列表。
  List<EmbyPcItem> items = <EmbyPcItem>[];
  List<EmbyPcItem> recentlyPlayed = const [];
  // 首页“最新入库”跨媒体库聚合，单独保存便于“换一批/刷新”时只重拉这一块。
  List<EmbyPcItem> homeLatest = const [];
  Map<String, List<EmbyPcItem>> homeLibraryItems = const {};
  final Map<String, int?> libraryCounts = {};
  int? favoriteMovieCount;
  int? favoritePeopleCount;

  // ---- 当前查询条件 ----
  String activeId = '';
  String view = 'home';
  String itemType = '';
  String statusFilter = '';
  String markFilter = '';
  String videoType = '';
  // S5.6 筛选：流派、演员（PersonIds）与最低评分，候选值按媒体库懒加载后缓存。
  String genreFilter = '';
  String personFilter = '';
  String personFilterName = '';
  double? minRating;
  List<EmbyPcItem> genreOptions = const [];
  List<EmbyPcItem> personOptions = const [];
  String genreOptionsLibrary = '';
  bool facetLoading = false;
  String sortBy = 'PremiereDate';
  String sortOrder = 'Descending';
  String imageStyle = 'backdrop';
  // 搜索词与年份输入框由页面持有，这里只保存查询时的取值快照。
  String searchTerm = '';
  int? productionYear;

  // ---- 加载状态 ----
  int total = 0;
  bool loading = true;
  bool loadingMore = false;
  // 已有数据的前提下重新查询（筛选/排序/搜索）：列表保持可见，只在顶部显示细进度条。
  bool refreshing = false;
  bool homeLoading = false;
  bool homeLoaded = false;
  // 首页最近一次成功加载时间，用于回前台时判断是否值得自动刷新。
  DateTime? homeLoadedAt;
  bool countsLoading = true;
  bool favoritePeopleLoading = false;
  bool favoriteMovieLoading = false;
  String error = '';
  // 初始化失败的原始异常文本，只用于错误页的小字详情，便于排查。
  String errorDetail = '';
  String homeError = '';
  int queryVersion = 0;

  bool _disposed = false;

  // 收藏列表沿用原有查询语义，不接新增筛选条件。
  bool get favoriteView =>
      view == 'favorite-movies' || view == 'favorite-people';

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // 页面销毁后仍可能有请求在途，统一在这里截断状态回写。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // 恢复媒体库列表与列表偏好，成功后并行拉取侧栏计数与首页内容。
  // 失败直接抛出，由页面决定回登录页还是展示错误页。
  Future<void> initialize() async {
    final results = await Future.wait<dynamic>([
      _service.getLibraries(),
      _service.readPreferences(),
    ]);
    final libraries = results[0] as List<EmbyPcItem>;
    final preferences = results[1] as EmbyPcPreferences;
    this.libraries = applyLibraryOrder(libraries, preferences.libraryOrder);
    sortBy = preferences.sortBy;
    sortOrder = preferences.sortOrder;
    imageStyle = preferences.imageStyle == 'poster' ? 'poster' : 'backdrop';
    // 工作台默认进入首页，媒体库详情仅在用户选择后再按需加载。
    activeId = '';
    loading = false;
    // 重试成功后清掉上一次的错误，避免错误页或横幅残留在正常界面上。
    error = '';
    errorDetail = '';
    _notify();
    loadCounts();
    await loadHome();
  }

  // 初始化失败时的降级状态：保留已登录状态，只展示可重试的错误页。
  // message 面向用户，detail 保留原始异常供排查。
  void markInitializeFailed(String message, {String detail = ''}) {
    loading = false;
    error = message;
    errorDetail = detail;
    _notify();
  }

  Future<void> loadHome({bool force = false}) async {
    if (homeLoading || (homeLoaded && !force)) return;
    final snapshot = List<EmbyPcItem>.of(libraries);
    homeLoading = true;
    homeError = '';
    _notify();
    try {
      // 首页数据彼此独立，首次进入时并行获取继续观看、最新入库和各媒体库前十条。
      final results = await Future.wait<dynamic>([
        _service.getResumeItems(),
        _service.getLatestItems(limit: 24),
        ...snapshot.map(
          (library) => _service.getItems(libraryId: library.id, limit: 10),
        ),
      ]);
      if (_disposed) return;
      recentlyPlayed = (results[0] as EmbyPcPage).items;
      homeLatest = results[1] as List<EmbyPcItem>;
      homeLibraryItems = {
        for (var index = 0; index < snapshot.length; index++)
          snapshot[index].id: (results[index + 2] as EmbyPcPage).items,
      };
      homeLoading = false;
      homeLoaded = true;
      homeLoadedAt = DateTime.now();
      _notify();
    } catch (failure) {
      if (_disposed) return;
      homeLoading = false;
      homeError = failure.toString();
      _notify();
    }
  }

  void loadCounts() {
    countsLoading = true;
    favoriteMovieLoading = true;
    favoritePeopleLoading = true;
    final snapshot = List<EmbyPcItem>.of(libraries);
    _notify();
    for (final library in snapshot) {
      unawaited(_loadLibraryCount(library.id));
    }
    unawaited(_loadFavoriteCounts());
  }

  Future<void> _loadLibraryCount(String libraryId) async {
    try {
      final page = await _service.getItems(libraryId: libraryId, limit: 1);
      if (_disposed) return;
      libraryCounts[libraryId] = page.total;
      _notify();
    } catch (_) {
      if (_disposed) return;
      libraryCounts[libraryId] = null;
      _notify();
    }
  }

  Future<void> _loadFavoriteCounts() async {
    try {
      final results = await Future.wait<dynamic>([
        _service.getItems(favoriteOnly: true, limit: 1),
        _service.getItems(favoriteOnly: true, itemType: 'Person', limit: 1),
      ]);
      if (_disposed) return;
      favoriteMovieCount = (results[0] as EmbyPcPage).total;
      favoritePeopleCount = (results[1] as EmbyPcPage).total;
      favoriteMovieLoading = false;
      favoritePeopleLoading = false;
      countsLoading = false;
      _notify();
    } catch (_) {
      if (_disposed) return;
      favoriteMovieCount = null;
      favoritePeopleCount = null;
      favoriteMovieLoading = false;
      favoritePeopleLoading = false;
      countsLoading = false;
      _notify();
    }
  }

  // 列表与分页共用同一份查询快照，reset 为 false 时按当前条数追加。
  Future<void> loadItems({required bool reset}) async {
    if ((!reset && loadingMore) ||
        (!reset && items.length >= total && total > 0)) {
      return;
    }
    final requestVersion = reset ? ++queryVersion : queryVersion;
    if (reset) {
      // 已有数据时保留列表，用顶部细进度条提示刷新，避免每次筛选都白屏闪一下。
      refreshing = items.isNotEmpty;
      loading = !refreshing;
      loadingMore = false;
      error = '';
    } else {
      loadingMore = true;
    }
    _notify();
    try {
      final startIndex = reset ? 0 : items.length;
      final page = view == 'people'
          // 演员列表走 Persons 专用接口，返回整个服务器可见范围内的人物。
          ? await _service.getPersons(
              startIndex: startIndex,
              searchTerm: searchTerm,
              sortBy: sortBy,
              sortOrder: sortOrder,
            )
          : view == 'recently-played'
          ? await _service.getResumeItems(
              startIndex: startIndex,
              limit: 100,
              itemType: itemType,
              searchTerm: searchTerm,
              productionYear: productionYear,
              sortBy: sortBy,
              sortOrder: sortOrder,
            )
          : await _service.getItems(
              libraryId: view == 'library' ? activeId : '',
              favoriteOnly:
                  view == 'favorite-movies' || view == 'favorite-people',
              startIndex: startIndex,
              itemType: view == 'favorite-people' ? 'Person' : itemType,
              filters: view == 'favorite-movies' || view == 'favorite-people'
                  ? ''
                  : <String>[
                      // 非继续观看列表保留原有的状态和标记筛选。
                      statusFilter,
                      markFilter,
                    ].where((value) => value.isNotEmpty).join(','),
              videoType: videoType,
              searchTerm: searchTerm,
              productionYear: productionYear,
              // 收藏列表不接流派/演员/评分筛选，保持原有查询语义。
              genreIds: favoriteView ? const [] : <String>[
                if (genreFilter.isNotEmpty) genreFilter,
              ],
              personIds: favoriteView ? const [] : <String>[
                if (personFilter.isNotEmpty) personFilter,
              ],
              minCommunityRating: favoriteView ? null : minRating,
              sortBy: sortBy,
              sortOrder: sortOrder,
            );
      if (_disposed || requestVersion != queryVersion) return;
      if (reset) {
        items = page.items;
      } else {
        // 原地追加，滚动加载不再复制已加载的全部条目。
        items.addAll(page.items);
      }
      total = page.total;
      loading = false;
      loadingMore = false;
      refreshing = false;
      _notify();
    } catch (failure) {
      if (_disposed || requestVersion != queryVersion) return;
      loading = false;
      loadingMore = false;
      refreshing = false;
      error = failure.toString();
      _notify();
    }
  }

  // 切换视图时显式清空列表：旧视图的条目不能短暂显示在新标题下。
  void clearItems() {
    items = <EmbyPcItem>[];
    total = 0;
    error = '';
  }

  // 首页单个媒体库换一批：按 Random 排序只替换该分区，不影响其它分区。
  Future<void> shuffleHomeLibrary(String libraryId) async {
    if (homeLoading) return;
    try {
      final page = await _service.getItems(
        libraryId: libraryId,
        limit: 10,
        sortBy: 'Random',
        sortOrder: 'Ascending',
      );
      if (_disposed) return;
      homeLibraryItems = {...homeLibraryItems, libraryId: page.items};
      _notify();
    } catch (failure) {
      if (_disposed) return;
      homeError = failure.toString();
      _notify();
    }
  }

  // 回到前台时刷新首页：后台新增内容不必重进应用才可见。
  // 短时间反复切换窗口不重复请求，至少间隔 60 秒。
  Future<void> refreshHomeOnResume() async {
    if (!homeLoaded) return;
    final loadedAt = homeLoadedAt;
    if (loadedAt != null &&
        DateTime.now().difference(loadedAt) < const Duration(seconds: 60)) {
      return;
    }
    await loadHome(force: true);
  }

  // 保存列表偏好后按当前条件重新查询首页数据。
  Future<void> applyQuery() async {
    await _service.saveListPreferences(
      sortBy: sortBy,
      sortOrder: sortOrder,
      imageStyle: imageStyle,
    );
    await loadItems(reset: true);
  }

  // 流派候选值按当前媒体库加载一次并缓存；切库后重新拉取。
  // 失败时只清空候选值，不影响其它筛选项继续使用。
  Future<void> ensureGenreOptions() async {
    final parentId = view == 'library' ? activeId : '';
    if (facetLoading || genreOptionsLibrary == parentId) return;
    facetLoading = true;
    _notify();
    try {
      final genres = await _service.getGenres(parentId: parentId);
      if (_disposed) return;
      genreOptions = genres;
      genreOptionsLibrary = parentId;
      _notify();
    } catch (_) {
      if (_disposed) return;
      genreOptions = const [];
      _notify();
    } finally {
      if (!_disposed) {
        facetLoading = false;
        _notify();
      }
    }
  }

  // 演员筛选按关键词查人物，结果作为 PersonIds 候选。
  Future<void> searchPersons(String keyword) async {
    if (keyword.isEmpty) {
      personOptions = const [];
      _notify();
      return;
    }
    facetLoading = true;
    _notify();
    try {
      final page = await _service.getPersons(searchTerm: keyword, limit: 12);
      if (_disposed) return;
      personOptions = page.items;
      _notify();
    } catch (_) {
      if (_disposed) return;
      personOptions = const [];
      _notify();
    } finally {
      if (!_disposed) {
        facetLoading = false;
        _notify();
      }
    }
  }

  // 切换视图时清空查询条件，避免条件串到其它媒体库。
  void resetFilters() {
    itemType = '';
    statusFilter = '';
    markFilter = '';
    videoType = '';
    genreFilter = '';
    personFilter = '';
    personFilterName = '';
    personOptions = const [];
    minRating = null;
    searchTerm = '';
    productionYear = null;
  }

  // 用新条目替换列表与首页快照中的同一条内容，避免整页重拉。
  void _replaceItemEverywhere(EmbyPcItem updated) {
    final index = items.indexWhere((entry) => entry.id == updated.id);
    if (index >= 0) items[index] = updated;
    recentlyPlayed = _replaceInList(recentlyPlayed, updated);
    homeLatest = _replaceInList(homeLatest, updated);
    homeLibraryItems = {
      for (final library in homeLibraryItems.entries)
        library.key: _replaceInList(library.value, updated),
    };
  }

  // 只重建命中的那一条，避免每张卡片都随整表 map 重建。
  List<EmbyPcItem> _replaceInList(
    List<EmbyPcItem> source,
    EmbyPcItem updated,
  ) {
    final index = source.indexWhere((entry) => entry.id == updated.id);
    if (index < 0) return source;
    final next = List<EmbyPcItem>.of(source);
    next[index] = updated;
    return next;
  }

  // 收藏写入成功后同步本地列表与侧栏计数，避免整页重拉。
  void applyFavoriteResult(EmbyPcItem item, bool value) {
    _replaceItemEverywhere(item.copyWith(isFavorite: value));
    if (!value && view == 'favorite-movies') {
      items = items.where((entry) => entry.id != item.id).toList();
      total = (total - 1).clamp(0, 1 << 30).toInt();
    }
    if (view == 'favorite-movies' && favoriteMovieCount != null) {
      favoriteMovieCount = (favoriteMovieCount! + (value ? 1 : -1))
          .clamp(0, 1 << 30)
          .toInt();
    }
    // 从演员列表修改收藏时，同步侧栏的收藏演员数量。
    if ((view == 'favorite-people' || view == 'people') &&
        favoritePeopleCount != null) {
      favoritePeopleCount = (favoritePeopleCount! + (value ? 1 : -1))
          .clamp(0, 1 << 30)
          .toInt();
    }
    _notify();
  }

  // 标记已看后本地立即同步：列表角标与继续观看分区都不需要重新请求。
  void applyPlayedResult(EmbyPcItem item, bool value) {
    _replaceItemEverywhere(
      item.copyWith(
        played: value,
        // 已看的条目不再保留续播位置，卡片进度条要同步消失。
        playbackPositionTicks: value ? 0 : item.playbackPositionTicks,
      ),
    );
    // 继续观看只保留未看完的条目，标记已看后应立即从当前视图移除。
    if (value && view == 'recently-played') {
      items = items.where((entry) => entry.id != item.id).toList();
      total = (total - 1).clamp(0, 1 << 30).toInt();
    }
    _notify();
  }

  // 按已保存的顺序重排媒体库，未知 ID 忽略，新增库排在末尾。
  List<EmbyPcItem> applyLibraryOrder(
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
}
