part of 'emby_pc_page.dart';

// 工作台内容区域负责首页摘要与媒体库列表的视图组装。
extension _EmbyPcWorkspaceContent on _EmbyPcWorkspaceState {
  Widget _buildContent(BuildContext context, {required bool compact}) {
    // 人物没有背景图，演员列表和收藏演员均固定使用主图卡片。
    final peopleList = _c.view == 'people' || _c.view == 'favorite-people';
    final imageStyle = peopleList ? 'poster' : _c.imageStyle;
    // 背景图卡片沿用首页约 270 x 205 的视觉比例，并放宽列宽阈值，
    // 避免临界宽度下过早增加列数。
    final mediaGridMaxExtent = imageStyle == 'backdrop' ? 336.0 : 214.0;
    final mediaGridAspectRatio = imageStyle == 'backdrop' ? 1.28 : 0.585;
    // 分片影片是独立的管理视图：自带搜索与刷新，不复用媒体库列表的筛选工具栏。
    if (_c.view == 'part-groups') {
      return Column(
        children: [
          _EmbyPcWorkspaceToolbar(
            this,
          )._buildWorkspaceHeader(context, compact: compact),
          _EmbyPcWorkspaceToolbar(this)._buildPageHeading(context),
          Expanded(child: EmbyPcPartGroupsView(onOpenItem: _openItem)),
        ],
      );
    }
    return Column(
      children: [
        _EmbyPcWorkspaceToolbar(
          this,
        )._buildWorkspaceHeader(context, compact: compact),
        // 保留旧列表的同时用 2 像素细条提示正在刷新，避免整块白屏闪动。
        if (_c.refreshing) const LinearProgressIndicator(minHeight: 2),
        // 首页直接让主视觉接住页头，内容页则用大标题作为页面级标题。
        if (_c.view != 'home')
          _EmbyPcWorkspaceToolbar(this)._buildPageHeading(context),
        if (_c.view != 'home')
          _EmbyPcWorkspaceToolbar(this)._buildToolbar(context),
        if (_c.view != 'home' && _c.error.isNotEmpty)
          MaterialBanner(
            content: Text(_c.error),
            actions: [
              TextButton(
                onPressed: () => _c.loadItems(reset: true),
                child: const Text('重试'),
              ),
            ],
          ),
        Expanded(
          // 首页与媒体库共用同一份滚动控制器，回到顶部按钮跟随视图重算位置。
          child: EmbyPcScrollToTop(
            controller: _scrollController,
            builder: (context, _) => _c.view == 'home'
                ? _buildHomeContent(context)
                : _c.loading && _c.items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _c.items.isEmpty
                ? _EmptyState(
                    hasFilters: _hasActiveFilters,
                    onClearFilters: _clearAllFilters,
                  )
                : CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      SliverPadding(
                        // 媒体库详情仅展示视频网格，不再插入精选横幅。
                        padding: EdgeInsets.fromLTRB(
                          compact ? 14 : 28,
                          10,
                          compact ? 14 : 28,
                          40,
                        ),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: mediaGridMaxExtent,
                                crossAxisSpacing: 18,
                                mainAxisSpacing: 24,
                                childAspectRatio: mediaGridAspectRatio,
                              ),
                          itemCount: _c.items.length,
                          itemBuilder: (context, index) {
                            final item = _c.items[index];
                            return EmbyPcMediaTile(
                              item: item,
                              imageStyle: imageStyle,
                              secondaryLabel: peopleList
                                  ? _personBirthYear(item)
                                  : _c.view == 'watch-history'
                                  ? item.lastPlayedLabel
                                  : '',
                              hideDefaultMetadata: peopleList,
                              favoriteBusy: _favoriteBusyIds.contains(item.id),
                              actionBusy: _mediaActionBusyIds.contains(item.id),
                              onOpen: () => _openItem(item),
                              onPlay: peopleList ? null : () => _playItem(item),
                              onFavorite: () => _toggleFavorite(item),
                              onAction: (action) =>
                                  _handleMediaAction(item, action),
                            );
                          },
                        ),
                      ),
                      if (_c.loadingMore)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(26, 0, 26, 30),
                          sliver: SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: mediaGridMaxExtent,
                                  crossAxisSpacing: 20,
                                  mainAxisSpacing: 22,
                                  childAspectRatio: mediaGridAspectRatio,
                                ),
                            itemCount: 6, // 显示 6 个骨架屏占位符
                            itemBuilder: (context, index) {
                              return EmbyPcLoadingPlaceholder(
                                isBackdrop: imageStyle == 'backdrop',
                              );
                            },
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  // Emby 人物 DTO 使用 PremiereDate 保存出生日期，列表只展示其年份。
  String _personBirthYear(EmbyPcItem person) {
    final date = DateTime.tryParse(person.premiereDate);
    if (date != null) return '${date.year}';
    final match = RegExp(r'^\d{4}').firstMatch(person.premiereDate);
    return match?.group(0) ?? '';
  }

  Widget _buildHomeContent(BuildContext context) {
    if (_c.homeLoading && !_c.homeLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_c.homeError.isNotEmpty && !_c.homeLoaded) {
      return _WorkspaceError(
        message: '首页加载失败',
        detail: _c.homeError,
        onRetry: () => _c.loadHome(force: true),
      );
    }
    final featured = _homeFeaturedItems;
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (_c.homeError.isNotEmpty)
          SliverToBoxAdapter(
            child: MaterialBanner(
              content: Text(_c.homeError),
              actions: [
                TextButton(
                  onPressed: () => _c.loadHome(force: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        // 顶部主视觉轮播：继续观看优先，其次是带背景图的最新内容。
        if (featured.isNotEmpty)
          SliverToBoxAdapter(
            child: _HomeHeroCarousel(
              items: featured,
              favoriteBusyIds: _favoriteBusyIds,
              onPlay: _playItem,
              onOpen: _openItem,
              onFavorite: _toggleFavorite,
            ),
          ),
        SliverToBoxAdapter(child: _buildHomeLibraries(context)),
        SliverToBoxAdapter(
          child: _buildHomeMediaSection(
            context,
            title: '观看历史',
            items: _c.watchHistory,
            showLastPlayedTime: true,
            onOpenSection: _selectWatchHistory,
          ),
        ),
        // 最新入库聚合全部媒体库，避免只在各库分区里各看十条。
        if (_c.homeLatest.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildHomeMediaSection(
              context,
              title: '最新入库',
              items: _c.homeLatest,
              onOpenSection: _selectLatest,
            ),
          ),
        ..._c.libraries.map(
          (library) => SliverToBoxAdapter(
            child: _buildHomeMediaSection(
              context,
              title: library.name,
              items: _c.homeLibraryItems[library.id] ?? const [],
              onOpenSection: () => _selectLibrary(library.id),
              // 单个分区换一批，不影响其它媒体库的展示顺序。
              onShuffle: () => _c.shuffleHomeLibrary(library.id),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 36)),
      ],
    );
  }

  // 轮播候选：观看历史（带进度优先）→ 最新入库 → 各媒体库，只取带背景图的前 5 条。
  List<EmbyPcItem> get _homeFeaturedItems {
    const limit = 5;
    final seen = <String>{};
    final result = <EmbyPcItem>[];

    void collect(Iterable<EmbyPcItem> source) {
      for (final item in source) {
        if (result.length >= limit) return;
        if (!item.hasBackdropImage) continue;
        if (seen.add(item.id)) result.add(item);
      }
    }

    collect(_c.watchHistory.where((item) => item.playbackPositionTicks > 0));
    collect(_c.watchHistory);
    collect(_c.homeLatest);
    for (final library in _c.libraries) {
      collect(_c.homeLibraryItems[library.id] ?? const []);
    }
    return result;
  }

  // 分区标题：渐变竖条 + 标题 + “更多”入口，右侧可挂刷新/换一批。
  Widget _buildHomeSectionHeader(
    BuildContext context, {
    required String title,
    String? trailingLabel,
    VoidCallback? onMore,
    VoidCallback? onShuffle,
    bool shuffleEnabled = true,
    Widget? trailing,
  }) {
    final skin = EmbyPcSkin.of(context);
    return Row(
      children: [
        Container(
          width: 4,
          height: 17,
          decoration: BoxDecoration(
            gradient: skin.accentFill,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Microsoft YaHei UI',
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: skin.scheme.onSurface,
            ),
          ),
        ),
        if (trailingLabel != null) ...[
          const SizedBox(width: 8),
          Text(
            trailingLabel,
            style: TextStyle(fontSize: 11.5, color: skin.textTertiary),
          ),
        ],
        if (onMore != null) ...[
          const SizedBox(width: 2),
          TextButton(
            onPressed: onMore,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: skin.textTertiary,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('更多'),
                Icon(Icons.chevron_right_rounded, size: 16),
              ],
            ),
          ),
        ],
        const Spacer(),
        if (onShuffle != null)
          IconButton(
            tooltip: '换一批$title',
            visualDensity: VisualDensity.compact,
            onPressed: shuffleEnabled ? onShuffle : null,
            style: IconButton.styleFrom(
              minimumSize: const Size.square(34),
              foregroundColor: skin.textSecondary,
            ),
            icon: const Icon(Icons.autorenew_rounded, size: 18),
          ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _buildHomeLibraries(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 14 : 28, 22, narrow ? 14 : 28, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHomeSectionHeader(
            context,
            title: '媒体库',
            trailingLabel: _c.libraries.isEmpty
                ? null
                : '${_c.libraries.length} 个',
            // 首页手动刷新：后台扫描入库后不必重进应用即可看到新内容。
            trailing: IconButton(
              tooltip: '刷新首页',
              visualDensity: VisualDensity.compact,
              onPressed: _c.homeLoading ? null : () => _c.loadHome(force: true),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(34),
                foregroundColor: skin.textSecondary,
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
          ),
          const SizedBox(height: 12),
          if (_c.libraries.isEmpty)
            SizedBox(
              height: 96,
              child: Center(
                child: Text(
                  '暂无媒体库',
                  style: TextStyle(color: skin.textSecondary),
                ),
              ),
            )
          else
            EmbyPcHorizontalCarousel(
              height: 168,
              itemWidth: 246,
              itemCount: _c.libraries.length,
              spacing: 16,
              navigationLabel: '媒体库',
              padding: EdgeInsets.zero,
              itemBuilder: (context, index) {
                final library = _c.libraries[index];
                return _HomeLibraryTile(
                  library: library,
                  busy: _libraryActionBusyIds.contains(library.id),
                  onPressed: () => _selectLibrary(library.id),
                  onAction: (action) => _handleLibraryAction(library, action),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildHomeMediaSection(
    BuildContext context, {
    required String title,
    required List<EmbyPcItem> items,
    bool showLastPlayedTime = false,
    VoidCallback? onOpenSection,
    VoidCallback? onShuffle,
  }) {
    final skin = EmbyPcSkin.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 14 : 28, 20, narrow ? 14 : 28, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHomeSectionHeader(
            context,
            title: title,
            onMore: onOpenSection,
            onShuffle: onShuffle,
            shuffleEnabled: !_c.homeLoading,
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            SizedBox(
              height: 84,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '暂无内容',
                  style: TextStyle(color: skin.textSecondary),
                ),
              ),
            )
          else
            EmbyPcHorizontalCarousel(
              height: 196,
              itemWidth: 296,
              itemCount: items.length,
              spacing: 18,
              navigationLabel: title,
              padding: EdgeInsets.zero,
              itemBuilder: (context, index) {
                final item = items[index];
                return EmbyPcMediaTile(
                  item: item,
                  imageStyle: 'backdrop',
                  // 首页横排改用图片内嵌标题，观感更接近视频平台的推荐位。
                  overlayCaption: true,
                  secondaryLabel: showLastPlayedTime
                      ? item.lastPlayedLabel
                      : '',
                  favoriteBusy: _favoriteBusyIds.contains(item.id),
                  actionBusy: _mediaActionBusyIds.contains(item.id),
                  onOpen: () => _openItem(item),
                  onPlay: () => _playItem(item),
                  // 首页横向列表与详情网格共用收藏交互。
                  onFavorite: () => _toggleFavorite(item),
                  onAction: (action) => _handleMediaAction(item, action),
                );
              },
            ),
        ],
      ),
    );
  }
}
