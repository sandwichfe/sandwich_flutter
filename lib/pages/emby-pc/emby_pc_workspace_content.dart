part of 'emby_pc_page.dart';

// 工作台内容区域负责首页摘要与媒体库列表的视图组装。
extension _EmbyPcWorkspaceContent on _EmbyPcWorkspaceState {
  Widget _buildContent(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    // 人物没有背景图，演员列表和收藏演员均固定使用主图卡片。
    final peopleList = _c.view == 'people' || _c.view == 'favorite-people';
    final imageStyle = peopleList ? 'poster' : _c.imageStyle;
    // 背景图卡片沿用首页约 270 x 205 的视觉比例，并放宽列宽阈值，
    // 避免临界宽度下过早增加列数。
    final mediaGridMaxExtent = imageStyle == 'backdrop' ? 336.0 : 214.0;
    final mediaGridAspectRatio = imageStyle == 'backdrop' ? 1.28 : 0.585;
    // 分片影片是独立的管理视图：自带搜索与刷新，不复用媒体库列表的筛选工具栏。
    if (_c.view == 'part-groups') {
      return ColoredBox(
        color: colors.surfaceContainerLowest,
        child: Column(
          children: [
            _EmbyPcWorkspaceToolbar(
              this,
            )._buildWorkspaceHeader(context, compact: compact),
            Expanded(
              child: EmbyPcPartGroupsView(onOpenItem: _openItem),
            ),
          ],
        ),
      );
    }
    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Column(
        children: [
          _EmbyPcWorkspaceToolbar(
            this,
          )._buildWorkspaceHeader(context, compact: compact),
          // 保留旧列表的同时用 2 像素细条提示正在刷新，避免整块白屏闪动。
          if (_c.refreshing) const LinearProgressIndicator(minHeight: 2),
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
              builder:
                  (context, _) =>
                      _c.view == 'home'
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
                                padding: const EdgeInsets.fromLTRB(
                                  26,
                                  18,
                                  26,
                                  30,
                                ),
                                sliver: SliverGrid.builder(
                                  gridDelegate:
                                      SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: mediaGridMaxExtent,
                                        crossAxisSpacing: 20,
                                        mainAxisSpacing: 22,
                                        childAspectRatio: mediaGridAspectRatio,
                                      ),
                                  itemCount: _c.items.length,
                                  itemBuilder: (context, index) {
                                    final item = _c.items[index];
                                    return EmbyPcMediaTile(
                                      item: item,
                                      imageStyle: imageStyle,
                                      secondaryLabel:
                                          peopleList
                                              ? _personBirthYear(item)
                                              : _c.view == 'watch-history'
                                              ? item.lastPlayedLabel
                                              : '',
                                      hideDefaultMetadata: peopleList,
                                      favoriteBusy: _favoriteBusyIds.contains(
                                        item.id,
                                      ),
                                      actionBusy: _mediaActionBusyIds.contains(
                                        item.id,
                                      ),
                                      onOpen: () => _openItem(item),
                                      onPlay:
                                          peopleList
                                              ? null
                                              : () => _playItem(item),
                                      onFavorite:
                                          () => _toggleFavorite(item),
                                      onAction:
                                          (action) => _handleMediaAction(
                                            item,
                                            action,
                                          ),
                                    );
                                  },
                                ),
                              ),
                              if (_c.loadingMore)
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    26,
                                    0,
                                    26,
                                    30,
                                  ),
                                  sliver: SliverGrid.builder(
                                    gridDelegate:
                                        SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent:
                                              mediaGridMaxExtent,
                                          crossAxisSpacing: 20,
                                          mainAxisSpacing: 22,
                                          childAspectRatio:
                                              mediaGridAspectRatio,
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
      ),
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
        const SliverToBoxAdapter(child: SizedBox(height: 30)),
      ],
    );
  }

  Widget _buildHomeLibraries(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 18, 26, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '媒体库',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              // 首页手动刷新：后台扫描入库后不必重进应用即可看到新内容。
              IconButton(
                tooltip: '刷新首页',
                visualDensity: VisualDensity.compact,
                onPressed: _c.homeLoading ? null : () => _c.loadHome(force: true),
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_c.libraries.isEmpty)
            const SizedBox(height: 80, child: Center(child: Text('暂无媒体库')))
          else
            EmbyPcHorizontalCarousel(
              height: 164,
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
    final titleWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (onOpenSection != null) ...[
          const SizedBox(width: 3),
          const Icon(Icons.chevron_right, size: 21),
        ],
      ],
    );
    final titleBlock =
        onOpenSection == null
            ? titleWidget
            : InkWell(
              onTap: onOpenSection,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: titleWidget,
              ),
            );
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 18, 26, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: titleBlock),
              if (onShuffle != null)
                IconButton(
                  tooltip: '换一批$title',
                  visualDensity: VisualDensity.compact,
                  onPressed: _c.homeLoading ? null : onShuffle,
                  icon: const Icon(Icons.autorenew_rounded, size: 19),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const SizedBox(
              height: 72,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无内容'),
              ),
            )
          else
            EmbyPcHorizontalCarousel(
              height: 205,
              itemWidth: 270,
              itemCount: items.length,
              spacing: 18,
              navigationLabel: title,
              padding: EdgeInsets.zero,
              itemBuilder: (context, index) {
                final item = items[index];
                return EmbyPcMediaTile(
                  item: item,
                  imageStyle: 'backdrop',
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
