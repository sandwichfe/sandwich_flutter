part of 'emby_pc_page.dart';

// 工作台导航区域集中处理标题、账号菜单和桌面侧栏。
extension _EmbyPcWorkspaceNavigation on _EmbyPcWorkspaceState {
  String get _pageTitle {
    if (_c.view == 'home') return '首页';
    if (_c.view == 'watch-history') return '观看历史';
    if (_c.view == 'latest') return '最新入库';
    if (_c.view == 'people') return '演员列表';
    if (_c.view == 'part-groups') return '分片影片';
    if (_c.view == 'favorite-movies') return '收藏影片';
    if (_c.view == 'favorite-people') return '收藏演员';
    for (final library in _c.libraries) {
      if (library.id == _c.activeId) return library.name;
    }
    return '媒体库';
  }

  Widget _buildSearchField(double width) {
    final skin = EmbyPcSkin.of(context);
    return SizedBox(
      width: width,
      height: 44,
      child: TextField(
        controller: _searchController,
        // 首页没有本地列表：回车直接打开全库搜索，其余视图继续走本地筛选。
        onChanged: _c.view == 'home' ? null : _scheduleSearch,
        onSubmitted: (value) {
          if (_c.view == 'home') {
            unawaited(_openGlobalSearch());
            return;
          }
          _submitSearch(value);
        },
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: skin.surfaceAlt.withValues(alpha: skin.dark ? 0.78 : 1),
          hintText: '搜索片名、演员、类型',
          hintStyle: TextStyle(fontSize: 13, color: skin.textTertiary),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          // 收紧图标约束，44 高的圆角搜索框不会被默认 48 的图标撑高。
          prefixIconConstraints: const BoxConstraints(
            minWidth: 42,
            minHeight: 38,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 38,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 19,
            color: skin.textSecondary,
          ),
          suffixIcon: _searchController.text.isEmpty
              ? IconButton(
                  tooltip: _c.view == 'home' ? '搜索全部内容' : '搜索',
                  onPressed: _c.view == 'home'
                      ? _openGlobalSearch
                      : (_c.loading ? null : _applyQuery),
                  icon: Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: skin.textSecondary,
                  ),
                )
              : IconButton(
                  tooltip: '清除搜索',
                  onPressed: _c.loading ? null : _clearSearch,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: skin.textSecondary,
                  ),
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
            borderSide: BorderSide(color: skin.hairline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
            borderSide: BorderSide(color: skin.hairline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
            borderSide: BorderSide(color: skin.accent, width: 1.3),
          ),
        ),
      ),
    );
  }

  // 页头账号入口：头像 + 昵称 + 账号标识，点按展开账号菜单。
  // 设置已独立成页头按钮，菜单只保留账号相关的退出登录。
  Widget _buildAccountMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final skin = EmbyPcSkin.of(context);
    final service = EmbyPcService.instance;
    final userName = service.currentUserName.trim();
    final displayName = userName.isEmpty ? '当前用户' : userName;
    // 没有头像标记时地址为空，直接走占位图标，不发起图片请求。
    final avatarUrl = service.userAvatarUrl();
    final avatarImage = avatarUrl == null ? null : NetworkImage(avatarUrl);
    // 菜单入口和账号信息区共用头像样式，仅通过半径区分信息层级。
    Widget buildAvatar(double radius) => CircleAvatar(
      radius: radius,
      backgroundColor: colors.surfaceContainerHighest,
      foregroundImage: avatarImage,
      // 用户未设置头像或图片请求失败时显示稳定的账号占位图标；
      // 失败一次就标记为不可用，避免页面重建时反复请求同一个 404 地址。
      onForegroundImageError: avatarImage == null
          ? null
          : (_, _) => service.markUserAvatarUnavailable(),
      child: Icon(
        Icons.person_outline,
        size: radius + 4,
        color: colors.onSurfaceVariant,
      ),
    );
    final avatar = buildAvatar(14);
    // 窄窗口只剩头像时左右内边距必须对称，否则头像会偏在胶囊一侧。
    final showAccountDetails = MediaQuery.sizeOf(context).width >= 1100;
    final pill = Semantics(
      button: true,
      label: '用户 $displayName，打开账号菜单',
      child: Container(
        height: 40,
        padding: showAccountDetails
            ? const EdgeInsets.fromLTRB(4, 4, 10, 4)
            : const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: skin.surfaceAlt.withValues(alpha: skin.dark ? 0.62 : 1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: skin.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            // 窄窗口只留头像，避免账号区挤占搜索框。
            if (showAccountDetails) ...[
              const SizedBox(width: 9),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Microsoft YaHei UI',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: skin.scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  gradient: skin.accentFill,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'EMBY',
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: skin.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
    // 账号菜单只承载账号相关的退出登录，设置入口已放到页头。
    final menu = PopupMenuButton<String>(
      tooltip: '账号：$displayName',
      padding: EdgeInsets.zero,
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      constraints: const BoxConstraints.tightFor(width: 224),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      elevation: 8,
      shadowColor: colors.shadow.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.8)),
      ),
      onSelected: (value) {
        if (value == 'logout') _logout();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Semantics(
            container: true,
            label: 'Emby 账号 $displayName',
            child: Row(
              children: [
                buildAvatar(18),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.onSurface,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Emby 账号',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem(
          value: 'logout',
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.logout, size: 20, color: colors.error),
              const SizedBox(width: 12),
              Text('退出登录', style: TextStyle(color: colors.error, fontSize: 14)),
            ],
          ),
        ),
      ],
      child: pill,
    );
    return menu;
  }

  Widget _buildSidebar(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    // 宽度不做补间动画：折叠时文字会立即消失，动画中间态会挤压品牌行。
    return SizedBox(
      width: _sidebarCollapsed ? 72 : 252,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // 侧栏比画布略亮一层，用极细分隔线与内容分区。
          color: skin.sidebar,
          border: Border(right: BorderSide(color: skin.hairline)),
        ),
        child: Column(
          children: [
            _buildSidebarBrand(context),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  _sidebarCollapsed ? 12 : 14,
                  6,
                  _sidebarCollapsed ? 12 : 14,
                  8,
                ),
                children: [
                  if (!_sidebarCollapsed) const _SidebarSectionTitle('浏览'),
                  _SidebarButton(
                    icon: Icons.home_rounded,
                    title: '首页',
                    count: null,
                    showCount: false,
                    active: _c.view == 'home',
                    collapsed: _sidebarCollapsed,
                    onPressed: _selectHome,
                  ),
                  _SidebarButton(
                    icon: Icons.history_rounded,
                    title: '观看历史',
                    count: null,
                    showCount: false,
                    active: _c.view == 'watch-history',
                    collapsed: _sidebarCollapsed,
                    onPressed: _selectWatchHistory,
                  ),
                  Divider(height: _sidebarCollapsed ? 18 : 26),
                  if (!_sidebarCollapsed) const _SidebarSectionTitle('媒体库'),
                  ..._c.libraries.map(
                    (library) => _SidebarButton(
                      icon: Icons.video_library_rounded,
                      title: library.name,
                      count: _c.libraryCounts[library.id],
                      active: _c.view == 'library' && library.id == _c.activeId,
                      collapsed: _sidebarCollapsed,
                      onPressed: () => _selectLibrary(library.id),
                    ),
                  ),
                  // 媒体库与全局入口分组显示，便于区分内容来源。
                  Divider(height: _sidebarCollapsed ? 18 : 26),
                  _SidebarButton(
                    icon: Icons.call_split_rounded,
                    title: '分片影片',
                    count: null,
                    showCount: false,
                    active: _c.view == 'part-groups',
                    collapsed: _sidebarCollapsed,
                    onPressed: _selectPartGroups,
                  ),
                  _SidebarButton(
                    icon: Icons.groups_rounded,
                    title: '演员列表',
                    count: null,
                    showCount: false,
                    active: _c.view == 'people',
                    collapsed: _sidebarCollapsed,
                    onPressed: _selectPeople,
                  ),
                  Divider(height: _sidebarCollapsed ? 18 : 26),
                  if (!_sidebarCollapsed) const _SidebarSectionTitle('收藏'),
                  _SidebarButton(
                    icon: Icons.movie_creation_rounded,
                    title: '影片',
                    count: _c.favoriteMovieCount,
                    active: _c.view == 'favorite-movies',
                    loading: _c.favoriteMovieLoading,
                    collapsed: _sidebarCollapsed,
                    onPressed: () => _selectFavorites('favorite-movies'),
                  ),
                  _SidebarButton(
                    icon: Icons.person_rounded,
                    title: '演员',
                    count: _c.favoritePeopleCount,
                    active: _c.view == 'favorite-people',
                    loading: _c.favoritePeopleLoading,
                    collapsed: _sidebarCollapsed,
                    onPressed: () => _selectFavorites('favorite-people'),
                  ),
                  // 统计数字不跟随定时刷新，由用户在这里显式重新统计。
                  Divider(height: _sidebarCollapsed ? 18 : 26),
                  _SidebarButton(
                    icon: Icons.refresh_rounded,
                    title: '刷新统计',
                    count: null,
                    showCount: false,
                    active: false,
                    loading: _c.countsRefreshing,
                    collapsed: _sidebarCollapsed,
                    onPressed: _refreshCounts,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 侧栏顶部品牌区：渐变播放标 + 产品名，右侧提供折叠入口。
  Widget _buildSidebarBrand(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final mark = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        gradient: skin.brandGradient,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: skin.accent.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        size: 23,
        color: Colors.white,
      ),
    );
    if (_sidebarCollapsed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 10),
        child: Column(
          children: [
            mark,
            const SizedBox(height: 10),
            _buildSidebarToggle(context),
          ],
        ),
      );
    }
    // 高度与页头共用同一常量，品牌标与搜索框处在同一条视觉基线上。
    return SizedBox(
      height: EmbyPcHeaderMetrics.height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 10, 0),
        child: Row(
          children: [
            mark,
            const SizedBox(width: 12),
            Expanded(
              // 品牌文字区同时作为窗口拖动区，符合桌面端从左上角拖窗口的习惯。
              child: _brandTitleArea(context),
            ),
            _buildSidebarToggle(context),
          ],
        ),
      ),
    );
  }

  // 侧栏品牌文字：产品名 + 副标题，Windows 上兼作窗口拖动区。
  Widget _brandTitleArea(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final title = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '媒体中心',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Microsoft YaHei UI',
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: skin.scheme.onSurface,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'EMBY · PC',
          maxLines: 1,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.2,
            color: skin.textTertiary,
          ),
        ),
      ],
    );
    if (!_usesWindowsChrome) return title;
    return WindowsDragArea(child: title);
  }

  Widget _buildMobileNavigationDrawer(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final drawerWidth = screenWidth * 0.82 > 320 ? 320.0 : screenWidth * 0.82;
    // 移动端抽屉复用桌面侧栏条目，使分组、数量和选中态保持一致。
    return Drawer(
      width: drawerWidth,
      backgroundColor: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              // 抽屉品牌区与页头同高，两套导航观感一致。
              height: EmbyPcHeaderMetrics.height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    // 抽屉顶部沿用侧栏品牌标，保持两套导航观感一致。
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        gradient: EmbyPcSkin.of(context).brandGradient,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 19,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '媒体中心',
                        style: TextStyle(
                          fontFamily: 'Microsoft YaHei UI',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: EmbyPcSkin.of(context).scheme.onSurface,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭导航',
                      onPressed: () =>
                          _workspaceScaffoldKey.currentState?.closeDrawer(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
                children: [
                  _SidebarButton(
                    icon: Icons.home_outlined,
                    title: '首页',
                    count: null,
                    showCount: false,
                    active: _c.view == 'home',
                    onPressed: () => _selectFromMobileNavigation(_selectHome),
                  ),
                  _SidebarButton(
                    icon: Icons.history_rounded,
                    // 与侧栏、页面标题统一为“观看历史”，避免同一视图多种叫法。
                    title: '观看历史',
                    count: null,
                    showCount: false,
                    active: _c.view == 'watch-history',
                    onPressed: () =>
                        _selectFromMobileNavigation(_selectWatchHistory),
                  ),
                  const Divider(height: 28),
                  const _SidebarSectionTitle('媒体库'),
                  ..._c.libraries.map(
                    (library) => _SidebarButton(
                      icon: Icons.video_library_outlined,
                      title: library.name,
                      count: _c.libraryCounts[library.id],
                      active: _c.view == 'library' && library.id == _c.activeId,
                      onPressed: () => _selectFromMobileNavigation(
                        () => _selectLibrary(library.id),
                      ),
                    ),
                  ),
                  // 全局入口与媒体库分组显示，避免与动态媒体库名称混淆。
                  const Divider(height: 28),
                  _SidebarButton(
                    icon: Icons.call_split_rounded,
                    title: '分片影片',
                    count: null,
                    showCount: false,
                    active: _c.view == 'part-groups',
                    onPressed: () =>
                        _selectFromMobileNavigation(_selectPartGroups),
                  ),
                  _SidebarButton(
                    icon: Icons.groups_outlined,
                    title: '演员列表',
                    count: null,
                    showCount: false,
                    active: _c.view == 'people',
                    onPressed: () => _selectFromMobileNavigation(_selectPeople),
                  ),
                  const Divider(height: 28),
                  const _SidebarSectionTitle('收藏'),
                  _SidebarButton(
                    icon: Icons.movie_outlined,
                    title: '影片',
                    count: _c.favoriteMovieCount,
                    active: _c.view == 'favorite-movies',
                    loading: _c.favoriteMovieLoading,
                    onPressed: () => _selectFromMobileNavigation(
                      () => _selectFavorites('favorite-movies'),
                    ),
                  ),
                  _SidebarButton(
                    icon: Icons.person_outline,
                    title: '演员',
                    count: _c.favoritePeopleCount,
                    active: _c.view == 'favorite-people',
                    loading: _c.favoritePeopleLoading,
                    onPressed: () => _selectFromMobileNavigation(
                      () => _selectFavorites('favorite-people'),
                    ),
                  ),
                  // 抽屉同样提供手动刷新入口，与桌面侧栏保持一致。
                  const Divider(height: 28),
                  _SidebarButton(
                    icon: Icons.refresh_rounded,
                    title: '刷新统计',
                    count: null,
                    showCount: false,
                    active: false,
                    loading: _c.countsRefreshing,
                    onPressed: _refreshCounts,
                  ),
                  _SidebarButton(
                    icon: Icons.settings_outlined,
                    title: '设置',
                    count: null,
                    showCount: false,
                    active: false,
                    onPressed: () => _selectFromMobileNavigation(_openSettings),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 手动刷新侧栏统计：重新请求媒体库条目数与收藏影片/演员数量。
  // 请求期间按钮显示转圈并忽略重复点击，避免一次点击打出多轮请求。
  void _refreshCounts() {
    if (_c.countsRefreshing) return;
    unawaited(_c.loadCounts());
  }

  // 设置页由侧栏进入；返回后统一处理会话失效、头像与媒体库变更。
  Future<void> _openSettings() async {
    // 设置页使用标准 AppBar，恢复全局标题栏以保留窗口按钮。
    if (_usesWindowsChrome) WindowsTitleBar.embedded.value = false;
    try {
      await Navigator.of(
        context,
      ).push(embyPcFadeRoute(context, (_) => const SettingsPage()));
    } finally {
      // 会话被设置页清掉时留在登录页，由全局标题栏提供窗口按钮。
      if (mounted && _usesWindowsChrome && EmbyPcService.instance.isLoggedIn) {
        WindowsTitleBar.embedded.value = true;
      }
    }
    if (!mounted) return;
    // 设置页可以改服务器地址，改完当前会话立即作废，直接回登录页。
    if (!EmbyPcService.instance.isLoggedIn) {
      widget.onLogout();
      return;
    }
    // 设置页可能修改用户头像或媒体库，返回后同步刷新侧边栏与头像地址。
    _onWorkspaceChanged();
    // 媒体库管理里改过排序号，返回时按已保存的顺序重排侧栏。
    final order = (await EmbyPcService.instance.readPreferences()).libraryOrder;
    if (!mounted) return;
    await _reloadLibraries(order: order);
    // 媒体库管理页可能批量生成过海报/封面，返回后刷新当前列表的图片标记。
    await _reloadMediaAfterChange();
  }

  Widget _buildSidebarToggle(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    final label = _sidebarCollapsed ? '展开侧栏' : '收起侧栏';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
            child: SizedBox(
              width: 30,
              height: 30,
              child: Icon(
                _sidebarCollapsed
                    ? Icons.chevron_right_rounded
                    : Icons.chevron_left_rounded,
                size: 19,
                color: skin.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
