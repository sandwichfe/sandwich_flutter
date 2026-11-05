part of 'emby_pc_page.dart';

// 查询工具栏集中承载筛选、排序和布局切换控件。
extension _EmbyPcWorkspaceToolbar on _EmbyPcWorkspaceState {
  Widget _buildWorkspaceHeader(BuildContext context, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    // 仅移动端窄屏使用分层头部，Windows 等桌面平台继续保持原有排列。
    final stackedMobileHeader = _usesMobileWorkspaceLayout(
      MediaQuery.sizeOf(context).width,
    );
    final pageTitle = Text(
      _EmbyPcWorkspaceNavigation(this)._pageTitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.headlineSmall?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    );
    // 加载进度紧跟页面标题，并微调字面位置以与大字号标题视觉居中。
    final loadStatus = Transform.translate(
      offset: const Offset(0, 2),
      child: Text(
        _c.loading && _c.items.isEmpty
            ? '加载中'
            : '已加载 ${_c.items.length} 条 /  $_c.total 条',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      ),
    );
    if (stackedMobileHeader && _c.view != 'home') {
      return Material(
        color: colors.surfaceContainerLowest,
        child: Container(
          constraints: const BoxConstraints(minHeight: 118),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            children: [
              Row(
                children: [
                  _buildCompactLibraryMenu(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(child: pageTitle),
                        const SizedBox(width: 10),
                        Flexible(child: loadStatus),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _EmbyPcWorkspaceNavigation(
                    this,
                  )._buildAccountMenu(context),
                ],
              ),
              const SizedBox(height: 8),
              // 搜索框独占第二行，避免与标题、加载数量和账号入口互相挤压。
              _EmbyPcWorkspaceNavigation(
                this,
              )._buildSearchField(double.infinity),
            ],
          ),
        ),
      );
    }
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
            if (_c.view == 'home') ...[
              Expanded(child: pageTitle),
              const SizedBox(width: 8),
              _buildGlobalSearchButton(context, compact: compact),
            ] else ...[
              Expanded(
                child: Row(
                  children: [
                    Flexible(child: pageTitle),
                    const SizedBox(width: 10),
                    Flexible(child: loadStatus),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // 窄屏下允许搜索框随剩余空间收缩，避免固定宽度挤出工具栏。
              Flexible(
                child: _EmbyPcWorkspaceNavigation(
                  this,
                )._buildSearchField(compact ? 230 : 340),
              ),
            ],
            if (compact) ...[
              const SizedBox(width: 12),
              _EmbyPcWorkspaceNavigation(this)._buildAccountMenu(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalSearchButton(
      BuildContext context, {
        required bool compact,
      }) {
    final colors = Theme.of(context).colorScheme;
    if (compact) {
      return IconButton.outlined(
        tooltip: '搜索媒体库',
        onPressed: _openGlobalSearch,
        icon: const Icon(Icons.search_rounded, size: 20),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 42),
      child: OutlinedButton.icon(
        onPressed: _openGlobalSearch,
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          side: BorderSide(color: colors.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        icon: const Icon(Icons.search_rounded, size: 19),
        label: const Text('搜索媒体库'),
      ),
    );
  }

  Widget _buildCompactLibraryMenu() {
    if (_usesMobileWorkspaceLayout(MediaQuery.sizeOf(context).width)) {
      return IconButton(
        tooltip: '打开内容导航',
        onPressed: _openMobileNavigation,
        icon: const Icon(Icons.menu),
      );
    }
    return PopupMenuButton<String>(
      tooltip: '切换内容',
      icon: const Icon(Icons.menu),
      onSelected: (value) {
        if (value == 'home') {
          _selectHome();
        } else if (value == 'recently-played') {
          _selectRecentlyPlayed();
        } else if (value == 'people') {
          _selectPeople();
        } else if (value == 'favorite-movies' || value == 'favorite-people') {
          _selectFavorites(value);
        } else {
          _selectLibrary(value);
        }
      },
      itemBuilder:
          (_) => [
            const PopupMenuItem(value: 'home', child: Text('首页')),
            const PopupMenuItem(
              value: 'recently-played',
              child: Text('播放记录'),
            ),
            const PopupMenuDivider(),
            ..._c.libraries.map(
              (library) =>
                  PopupMenuItem(value: library.id, child: Text(library.name)),
            ),
            // 紧凑桌面布局使用弹出菜单替代侧栏，也保留演员列表入口。
            const PopupMenuItem(value: 'people', child: Text('演员列表')),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'favorite-movies',
              child: Text('收藏影片'),
            ),
            const PopupMenuItem(
              value: 'favorite-people',
              child: Text('收藏演员'),
            ),
          ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 移动端缩小工具栏留白，桌面端继续沿用原有间距。
    final compactMobileToolbar = _usesMobileWorkspaceLayout(
      MediaQuery.sizeOf(context).width,
    );
    // 人物接口没有视频筛选和布局参数，避免展示不会影响请求的控件。
    final peopleList = _c.view == 'people' || _c.view == 'favorite-people';
    return Material(
      color: colors.surfaceContainerLowest,
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding:
            compactMobileToolbar
                ? const EdgeInsets.fromLTRB(12, 4, 12, 10)
                : const EdgeInsets.fromLTRB(26, 4, 26, 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 安卓窄屏仅显示布局图标，完整含义继续由 Tooltip 提供。
            final compactLayoutControl =
                compactMobileToolbar || constraints.maxWidth < 420;
            return Row(
              children: [
                if (!peopleList) ...[
                  _buildFilterMenu(
                    context,
                    compact: compactMobileToolbar,
                  ),
                  SizedBox(width: compactMobileToolbar ? 6 : 8),
                ],
                _buildSortMenu(
                  context,
                  compact: compactMobileToolbar,
                ),
                const Spacer(),
                if (!peopleList)
                  _buildLayoutControl(
                    context,
                    compact: compactLayoutControl,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  int get _activeFilterCount =>
      [
        _c.itemType,
        _c.statusFilter,
        _c.markFilter,
        _c.videoType,
        _yearController.text.trim(),
        _c.genreFilter,
        _c.personFilter,
        _c.minRating?.toString() ?? '',
      ].where((value) => value.isNotEmpty).length;

  Widget _buildFilterMenu(
    BuildContext context, {
    bool compact = false,
  }) {
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
        _c.view != 'favorite-movies' &&
            _c.view != 'favorite-people' &&
            _c.view != 'recently-played';

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
                    selected: _c.itemType,
                    availableWidth: contentWidth,
                    onSelected: (value) {
                      if (value == _c.itemType) return;
                      setState(() => _c.itemType = value);
                      _applyQuery();
                    },
                  ),
                  if (showAdvancedFilters) ...[
                    _buildQueryGroup(
                      title: _c.genreOptions.isEmpty
                          ? '流派（加载中…）'
                          : '流派',
                      // 流派可能很多，只展示条目最多的前 12 个，避免面板过长。
                      options: {
                        '': '全部流派',
                        for (final genre in _c.genreOptions.take(12))
                          genre.id:
                              genre.childCount == null
                                  ? genre.name
                                  : '${genre.name} ${genre.childCount}',
                      },
                      selected: _c.genreFilter,
                      availableWidth: contentWidth,
                      onSelected: _selectGenre,
                    ),
                    _buildQueryGroup(
                      title: '最低评分',
                      options: const {
                        '': '不限评分',
                        '7': '7 分以上',
                        '8': '8 分以上',
                        '9': '9 分以上',
                      },
                      selected: _c.minRating?.toInt().toString() ?? '',
                      availableWidth: contentWidth,
                      onSelected: (value) =>
                          _selectMinRating(double.tryParse(value)),
                    ),
                  ],
                  if (showAdvancedFilters) ...[
                    _buildQueryGroup(
                      title: '播放状态',
                      options: statuses,
                      selected: _c.statusFilter,
                      availableWidth: contentWidth,
                      onSelected: (value) {
                        if (value == _c.statusFilter) return;
                        setState(() => _c.statusFilter = value);
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
                        enabled: !_c.loading,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _applyQuery(),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '年份',
                          suffixIcon: IconButton(
                            tooltip: '应用年份',
                            onPressed: _c.loading ? null : _applyQuery,
                            icon: const Icon(Icons.check, size: 18),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
                  if (showAdvancedFilters) ...[
                    const SizedBox(height: 14),
                    const Text(
                      '演员',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: contentWidth,
                      child: TextField(
                        controller: _personController,
                        enabled: !_c.loading,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _searchPersons(),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '输入演员名后回车',
                          suffixIcon: IconButton(
                            tooltip: '搜索演员',
                            onPressed: _c.loading ? null : _searchPersons,
                            icon: const Icon(Icons.search, size: 18),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    // 已选演员单独展示，便于一眼看出当前筛选并随时取消。
                    if (_c.personFilter.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: InputChip(
                          label: Text('演员：$_c.personFilterName'),
                          onDeleted: _c.loading ? null : _clearPersonFilter,
                        ),
                      ),
                    ],
                    if (_c.personOptions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final person in _c.personOptions)
                            ChoiceChip(
                              label: Text(person.name),
                              selected: person.id == _c.personFilter,
                              onSelected: _c.loading
                                  ? null
                                  : (_) => _selectPersonFilter(
                                      person.id,
                                      person.name,
                                    ),
                            ),
                        ],
                      ),
                    ],
                  ],
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
        compact: compact,
        onPressed:
        _c.loading
            ? null
            : () {
              if (controller.isOpen) {
                controller.close();
                return;
              }
              // 流派候选值只在打开面板时按需拉取，失败也不影响其余筛选。
              unawaited(_c.ensureGenreOptions());
              controller.open();
            },
      ),
    );
  }

  Widget _buildSortMenu(
    BuildContext context, {
    bool compact = false,
  }) {
    const sortOptions = {
      'CommunityRating': '评分',
      'Height': '分辨率',
      'DateCreated': '加入日期',
      'PremiereDate': '发行日期',
      'DatePlayed': '播放日期',
      'Runtime': '播放时长',
      'SortName': '文件名',
    };
    final availableWidth = MediaQuery.sizeOf(context).width - 24;
    final panelWidth = availableWidth > 320 ? 320.0 : availableWidth;
    final colors = Theme.of(context).colorScheme;

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
                Text('排序字段', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                // 当前字段再次点击时切换方向，其他字段沿用当前排序方向。
                ...sortOptions.entries.map((entry) {
                  final active = entry.key == _c.sortBy;
                  final ascending = _c.sortOrder == 'Ascending';
                  final currentOrder = ascending ? '升序' : '降序';
                  final nextOrder = ascending ? '降序' : '升序';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Semantics(
                      button: true,
                      selected: active,
                      excludeSemantics: true,
                      label:
                      active
                          ? '${entry.value}，当前$currentOrder，点击切换为$nextOrder'
                          : '${entry.value}，点击按此字段排序',
                      child: Material(
                        color:
                        active
                            ? colors.primary.withValues(alpha: 0.10)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap:
                          _c.loading
                              ? null
                              : () {
                            setState(() {
                              if (active) {
                                _c.sortOrder =
                                ascending
                                    ? 'Descending'
                                    : 'Ascending';
                              } else {
                                _c.sortBy = entry.key;
                              }
                            });
                            _applyQuery();
                          },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      entry.value,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium?.copyWith(
                                        color:
                                        active
                                            ? colors.primary
                                            : colors.onSurface,
                                        fontWeight:
                                        active
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                  if (active)
                                    Tooltip(
                                      message: currentOrder,
                                      child: Icon(
                                        ascending
                                            ? Icons.arrow_upward_rounded
                                            : Icons.arrow_downward_rounded,
                                        size: 18,
                                        color: colors.primary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ],
      builder:
          (context, controller, child) => _buildQueryPill(
        label: '排序',
        icon: Icons.swap_vert,
        compact: compact,
        onPressed:
        _c.loading
            ? null
            : () =>
        controller.isOpen
            ? controller.close()
            : controller.open(),
      ),
    );
  }

  Widget _buildLayoutControl(
    BuildContext context, {
    required bool compact,
  }) {
    final colors = Theme.of(context).colorScheme;
    return SegmentedButton<String>(
      showSelectedIcon: false,
      segments:
          compact
              ? const [
                ButtonSegment(
                  value: 'backdrop',
                  icon: Tooltip(
                    message: '背景图布局',
                    child: Icon(Icons.view_day_outlined),
                  ),
                ),
                ButtonSegment(
                  value: 'poster',
                  icon: Tooltip(
                    message: '海报布局',
                    child: Icon(Icons.view_agenda_outlined),
                  ),
                ),
              ]
              : const [
                ButtonSegment(
                  value: 'backdrop',
                  icon: Tooltip(
                    message: '背景图布局',
                    child: Icon(Icons.view_day_outlined),
                  ),
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
      selected: {_c.imageStyle},
      onSelectionChanged:
      _c.loading ? null : (selection) => _updateImageStyle(selection.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        // 布局选中态与侧栏、筛选项统一使用用户设置的主题色。
        foregroundColor: WidgetStateProperty.resolveWith(
              (states) =>
          states.contains(WidgetState.selected)
              ? colors.onPrimary
              : colors.onSurface,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
              (states) =>
          states.contains(WidgetState.selected)
              ? colors.primary
              : Colors.transparent,
        ),
        side: WidgetStateProperty.resolveWith(
              (states) => BorderSide(
            color:
            states.contains(WidgetState.selected)
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
    if (value == _c.imageStyle) return;
    setState(() => _c.imageStyle = value);
    await EmbyPcService.instance.saveListPreferences(
      sortBy: _c.sortBy,
      sortOrder: _c.sortOrder,
      imageStyle: _c.imageStyle,
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
            onPressed: _c.loading ? null : () => onSelected(entry.key),
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
    bool compact = false,
    required VoidCallback? onPressed,
  }) {
    final colors = Theme.of(context).colorScheme;
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 38),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      foregroundColor: active ? colors.primary : colors.onSurface,
      backgroundColor:
        active ? colors.primary.withValues(alpha: 0.10) : colors.surface,
      side: BorderSide(
        color: active ? colors.primary : colors.outlineVariant,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(width: 4),
        const Icon(Icons.keyboard_arrow_down, size: 17),
      ],
    );
    if (compact) {
      // 移动端保留明确的文字入口，省略重复图标以释放横向空间。
      return OutlinedButton(
        onPressed: onPressed,
        style: style,
        child: content,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 17),
      label: content,
    );
  }
}
