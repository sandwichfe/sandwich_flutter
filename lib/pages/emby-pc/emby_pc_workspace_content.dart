part of 'emby_pc_page.dart';

// 工作台内容区域负责首页摘要与媒体库列表的视图组装。
extension _EmbyPcWorkspaceContent on _EmbyPcWorkspaceState {
  Widget _buildContent(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    // 背景图卡片沿用首页约 270 x 205 的视觉比例，并放宽列宽阈值，
    // 避免临界宽度下过早增加列数。
    final mediaGridMaxExtent = _imageStyle == 'backdrop' ? 336.0 : 214.0;
    final mediaGridAspectRatio = _imageStyle == 'backdrop' ? 1.28 : 0.585;
    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Column(
        children: [
          _EmbyPcWorkspaceToolbar(
            this,
          )._buildWorkspaceHeader(context, compact: compact),
          if (_view != 'home')
            _EmbyPcWorkspaceToolbar(this)._buildToolbar(context),
          if (_view != 'home' && _error.isNotEmpty)
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
            child: _view == 'home'
                ? _buildHomeContent(context)
                : _loading && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? const _EmptyState()
                : CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      SliverPadding(
                        // 媒体库详情仅展示视频网格，不再插入精选横幅。
                        padding: const EdgeInsets.fromLTRB(26, 18, 26, 30),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: mediaGridMaxExtent,
                                crossAxisSpacing: 20,
                                mainAxisSpacing: 22,
                                childAspectRatio: mediaGridAspectRatio,
                              ),
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            return EmbyPcMediaTile(
                              item: item,
                              imageStyle: _imageStyle,
                              secondaryLabel: _view == 'recently-played'
                                  ? item.lastPlayedLabel
                                  : '',
                              favoriteBusy: _favoriteBusyIds.contains(item.id),
                              actionBusy: _mediaActionBusyIds.contains(item.id),
                              onOpen: () => _openItem(item),
                              onPlay: _view == 'favorite-people'
                                  ? null
                                  : () => _playItem(item),
                              onFavorite: () => _toggleFavorite(item),
                              onAction: (action) =>
                                  _handleMediaAction(item, action),
                            );
                          },
                        ),
                      ),
                      if (_loadingMore)
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
                                isBackdrop: _imageStyle == 'backdrop',
                              );
                            },
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeContent(BuildContext context) {
    if (_homeLoading && !_homeLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_homeError.isNotEmpty && !_homeLoaded) {
      return _WorkspaceError(
        message: _homeError,
        onRetry: () => _loadHome(force: true),
      );
    }
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (_homeError.isNotEmpty)
          SliverToBoxAdapter(
            child: MaterialBanner(
              content: Text(_homeError),
              actions: [
                TextButton(
                  onPressed: () => _loadHome(force: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        SliverToBoxAdapter(child: _buildHomeLibraries(context)),
        SliverToBoxAdapter(
          child: _buildHomeMediaSection(
            context,
            title: '继续观看',
            items: _recentlyPlayed,
            showLastPlayedTime: true,
            onOpenSection: _selectRecentlyPlayed,
          ),
        ),
        ..._libraries.map(
          (library) => SliverToBoxAdapter(
            child: _buildHomeMediaSection(
              context,
              title: library.name,
              items: _homeLibraryItems[library.id] ?? const [],
              onOpenSection: () => _selectLibrary(library.id),
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
          Text('媒体库', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (_libraries.isEmpty)
            const SizedBox(height: 80, child: Center(child: Text('暂无媒体库')))
          else
            EmbyPcHorizontalCarousel(
              height: 164,
              itemWidth: 246,
              itemCount: _libraries.length,
              spacing: 16,
              navigationLabel: '媒体库',
              padding: EdgeInsets.zero,
              itemBuilder: (context, index) {
                final library = _libraries[index];
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 18, 26, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onOpenSection == null)
            titleWidget
          else
            InkWell(
              onTap: onOpenSection,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: titleWidget,
              ),
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
