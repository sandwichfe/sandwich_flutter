part of 'emby_pc_page.dart';

// 工作台导航区域集中处理标题、账号菜单和桌面侧栏。
extension _EmbyPcWorkspaceNavigation on _EmbyPcWorkspaceState {
  String get _pageTitle {
    if (_view == 'home') return '首页';
    if (_view == 'recently-played') return '播放记录';
    if (_view == 'favorite-movies') return '收藏影片';
    if (_view == 'favorite-people') return '收藏演员';
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

  Widget _buildAccountMenu(
    BuildContext context, {
    bool sidebar = false,
    bool collapsed = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final userName = EmbyPcService.instance.currentUserName.trim();
    final displayName = userName.isEmpty ? '当前用户' : userName;
    final avatar = CircleAvatar(
      radius: 14,
      backgroundColor: colors.surfaceContainerHighest,
      foregroundImage: NetworkImage(
        EmbyPcService.instance.userAvatarUrl(),
      ),
      // 用户未设置头像或图片请求失败时显示稳定的账号占位图标。
      onForegroundImageError: (_, _) {},
      child: Icon(
        Icons.person_outline,
        size: 18,
        color: colors.onSurfaceVariant,
      ),
    );
    // 账号菜单固定在侧栏底部，仅保留账号相关操作和设置入口。
    final menu = PopupMenuButton<String>(
      tooltip: '账号：$displayName',
      padding: EdgeInsets.zero,
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      icon: sidebar ? null : avatar,
      onSelected: (value) {
        if (value == 'settings') {
          Navigator.of(
            context,
          ).push(
            embyPcFadeRoute(
              context,
              (_) => SettingsPage(onAdjustLibraryOrder: _openOrderDialog),
            ),
          );
        } else if (value == 'logout') {
          _logout();
        }
      },
      itemBuilder:
          (_) => [
            PopupMenuItem(enabled: false, child: Text(displayName)),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'settings',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.settings_outlined),
                title: Text('设置'),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'logout', child: Text('退出登录')),
          ],
      child:
          sidebar
              ? Semantics(
                button: true,
                label: '用户 $displayName，打开账号菜单',
                child: SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: Row(
                    mainAxisAlignment:
                        collapsed
                            ? MainAxisAlignment.center
                            : MainAxisAlignment.start,
                    children: [
                      SizedBox(width: collapsed ? 0 : 12),
                      avatar,
                      if (!collapsed) ...[
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Microsoft YaHei UI',
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.more_horiz,
                          size: 19,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                      ],
                    ],
                  ),
                ),
              )
              : null,
    );

    if (!sidebar) {
      return SizedBox.square(
        dimension: 42,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.82),
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: menu,
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.72),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: menu,
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
                  12,
                  _sidebarCollapsed ? 8 : 10,
                  8,
                ),
                children: [
                  _SidebarButton(
                    icon: Icons.home_outlined,
                    title: '首页',
                    count: null,
                    showCount: false,
                    active: _view == 'home',
                    collapsed: _sidebarCollapsed,
                    onPressed: _selectHome,
                  ),
                  _SidebarButton(
                    icon: Icons.history_rounded,
                    title: '播放记录',
                    count: null,
                    showCount: false,
                    active: _view == 'recently-played',
                    collapsed: _sidebarCollapsed,
                    onPressed: _selectRecentlyPlayed,
                  ),
                  Divider(height: _sidebarCollapsed ? 18 : 28),
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
                  if (!_sidebarCollapsed) const _SidebarSectionTitle('收藏'),
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
            // 折叠入口固定在账号区上方，避免顶部形成缺少标题的独立工具栏。
            _buildSidebarToggle(context),
            _buildAccountMenu(
              context,
              sidebar: true,
              collapsed: _sidebarCollapsed,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarToggle(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = _sidebarCollapsed ? '展开侧栏' : '收起侧栏';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap:
                  () => setState(
                    () => _sidebarCollapsed = !_sidebarCollapsed,
                  ),
              child: SizedBox(
                height: 40,
                child: Row(
                  mainAxisAlignment:
                      _sidebarCollapsed
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                  children: [
                    if (!_sidebarCollapsed) const SizedBox(width: 12),
                    Icon(
                      _sidebarCollapsed
                          ? Icons.chevron_right_rounded
                          : Icons.chevron_left_rounded,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                    if (!_sidebarCollapsed) ...[
                      const SizedBox(width: 11),
                      Text(
                        label,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontFamily: 'Microsoft YaHei UI',
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}
