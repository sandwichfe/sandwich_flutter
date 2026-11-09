part of 'emby_pc_page.dart';

// 查询工具栏集中承载筛选、排序和布局切换控件。
extension _EmbyPcWorkspaceToolbar on _EmbyPcWorkspaceState {
  // 筛选项文案集中一处：面板选项与工具栏条件标签共用，避免两处维护。
  static const Map<String, String> _itemTypeOptions = {
    '': '全部类型',
    'Movie': '电影',
    'Series': '剧集',
    'Video': '视频',
  };
  static const Map<String, String> _statusOptions = {
    '': '全部状态',
    'IsUnplayed': '未观看',
    'IsPlayed': '已观看',
    'IsResumable': '可继续',
  };
  static const Map<String, String> _videoTypeOptions = {
    '': '全部视频',
    'videofile': '视频文件',
    'dvd': 'DVD',
    'bluray': '蓝光',
    'iso': 'ISO',
  };
  static const Map<String, String> _ratingOptions = {
    '': '不限评分',
    '7': '7 分以上',
    '8': '8 分以上',
    '9': '9 分以上',
  };

  // 工作台唯一的顶部工具条：历史导航 + 全局搜索 + 账号 + 窗口按钮。
  Widget _buildWorkspaceHeader(BuildContext context, {required bool compact}) {
    final skin = EmbyPcSkin.of(context);
    final mobile = _usesMobileWorkspaceLayout(MediaQuery.sizeOf(context).width);
    final showWindowButtons = _usesWindowsChrome;
    // 背景、分割线、窗口拖动区与窗口按钮统一由页头外壳处理。
    return EmbyPcTopBarShell(
      color: skin.sidebar.withValues(alpha: skin.dark ? 0.94 : 0.96),
      hairline: skin.hairline,
      showWindowButtons: showWindowButtons,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 8 : 14,
          10,
          showWindowButtons ? 8 : (compact ? 10 : 16),
          10,
        ),
        child: Row(
          children: [
            if (compact) ...[
              _buildCompactLibraryMenu(),
              const SizedBox(width: 2),
            ],
            if (!mobile) ...[
              _buildHistoryButton(
                icon: Icons.chevron_left_rounded,
                tooltip: '后退',
                onPressed: _canGoBack ? _goBackView : null,
              ),
              _buildHistoryButton(
                icon: Icons.chevron_right_rounded,
                tooltip: '前进',
                onPressed: _canGoForward ? _goForwardView : null,
              ),
              const SizedBox(width: 10),
            ],
            // 搜索框吸收剩余空间，宽屏限制最大宽度，避免拉成一条长条。
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _EmbyPcWorkspaceNavigation(
                    this,
                  )._buildSearchField(double.infinity),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _buildHeaderAction(
              icon: Icons.refresh_rounded,
              tooltip: _c.view == 'home' ? '刷新首页' : '刷新列表',
              onPressed: _c.view == 'part-groups'
                  ? null
                  : () => unawaited(_refreshCurrentView()),
            ),
            // 移动端设置入口在抽屉里，页头省下空间给搜索框。
            if (!mobile)
              _buildHeaderAction(
                icon: Icons.settings_rounded,
                tooltip: '设置',
                onPressed: () => unawaited(_openSettings()),
              ),
            const SizedBox(width: 8),
            _EmbyPcWorkspaceNavigation(this)._buildAccountMenu(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final skin = EmbyPcSkin.of(context);
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 34,
            child: Icon(
              icon,
              size: 22,
              color: enabled
                  ? skin.textSecondary
                  : skin.textTertiary.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final skin = EmbyPcSkin.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 34,
            child: Icon(
              icon,
              size: 19,
              color: onPressed == null
                  ? skin.textTertiary.withValues(alpha: 0.4)
                  : skin.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _refreshCurrentView() async {
    if (_c.view == 'home') {
      await _c.loadHome(force: true);
      return;
    }
    _syncQueryInput();
    await _c.loadItems(reset: true);
  }

  // 列表进度摘要：页面大标题已去掉，条目数改为显示在工具栏右侧。
  String get _pageStatusText =>
      _c.loading && _c.items.isEmpty
      ? '正在载入'
      : _c.randomMode
      ? '随机 ${_c.items.length} 条 / 共 ${_c.total} 条'
      : '已加载 ${_c.items.length} 条 / 共 ${_c.total} 条';

  Widget _buildCompactLibraryMenu() {
    if (_usesMobileWorkspaceLayout(MediaQuery.sizeOf(context).width)) {
      return IconButton(
        tooltip: '打开内容导航',
        onPressed: _openMobileNavigation,
        icon: const Icon(Icons.menu_rounded, size: 21),
      );
    }
    return PopupMenuButton<String>(
      tooltip: '切换内容',
      icon: const Icon(Icons.menu_rounded, size: 21),
      onSelected: (value) {
        if (value == 'home') {
          _selectHome();
        } else if (value == 'watch-history') {
          _selectWatchHistory();
        } else if (value == 'people') {
          _selectPeople();
        } else if (value == 'part-groups') {
          _selectPartGroups();
        } else if (value == 'favorite-movies' || value == 'favorite-people') {
          _selectFavorites(value);
        } else {
          _selectLibrary(value);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'home', child: Text('首页')),
        const PopupMenuItem(value: 'watch-history', child: Text('观看历史')),
        const PopupMenuDivider(),
        ..._c.libraries.map(
          (library) =>
              PopupMenuItem(value: library.id, child: Text(library.name)),
        ),
        // 紧凑桌面布局使用弹出菜单替代侧栏，也保留分片影片与演员列表入口。
        const PopupMenuItem(value: 'part-groups', child: Text('分片影片')),
        const PopupMenuItem(value: 'people', child: Text('演员列表')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'favorite-movies', child: Text('收藏影片')),
        const PopupMenuItem(value: 'favorite-people', child: Text('收藏演员')),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    // 移动端缩小工具栏留白，桌面端继续沿用原有间距。
    final compactMobileToolbar = _usesMobileWorkspaceLayout(
      MediaQuery.sizeOf(context).width,
    );
    // 人物接口没有视频筛选和布局参数，避免展示不会影响请求的控件。
    final peopleList = _c.view == 'people' || _c.view == 'favorite-people';
    // 观看历史固定按最近播放时间倒序，筛选/排序/随机入口都失去意义，
    // 这里只保留一行排序说明和条目统计。
    if (_c.view == 'watch-history') {
      return _buildHistoryToolbar(context, compact: compactMobileToolbar);
    }
    // 人物列表共用影片筛选面板没有意义，这里不展示条件标签。
    final chips = peopleList ? const <Widget>[] : _buildFilterChips(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: compactMobileToolbar
            ? const EdgeInsets.fromLTRB(14, 6, 14, 12)
            : const EdgeInsets.fromLTRB(28, 8, 28, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // 安卓窄屏仅显示布局图标，完整含义继续由 Tooltip 提供。
                final compactLayoutControl =
                    compactMobileToolbar || constraints.maxWidth < 420;
                return Row(
                  children: [
                    if (!peopleList) ...[
                      _buildFilterMenu(context, compact: compactMobileToolbar),
                      SizedBox(width: compactMobileToolbar ? 6 : 8),
                    ],
                    _buildSortMenu(context, compact: compactMobileToolbar),
                    // 随机播放只对媒体列表有意义，人物列表不展示该入口。
                    if (!peopleList) ...[
                      SizedBox(width: compactMobileToolbar ? 6 : 8),
                      _buildShuffleButton(
                        context,
                        compact: compactMobileToolbar,
                        // 每次点击都会重新请求；请求在途时禁用，避免连点堆叠。
                        enabled: !_c.loading && !_c.refreshing && !_c.loadingMore,
                      ),
                    ],
                    // 条目统计替代原来的页面副标题，右对齐贴在布局切换左侧。
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compactMobileToolbar ? 8 : 12,
                        ),
                        child: Text(
                          _pageStatusText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 12,
                            color: skin.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    if (!peopleList)
                      _buildLayoutControl(
                        context,
                        compact: compactLayoutControl,
                      ),
                  ],
                );
              },
            ),
            // 已选条件常驻展示；高度变化走动画，避免条件增减时下面整块列表瞬移。
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: chips.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: EdgeInsets.only(
                        top: compactMobileToolbar ? 6 : 8,
                      ),
                      child: Wrap(spacing: 6, runSpacing: 6, children: chips),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // 工具栏下方的筛选条件标签：点击叉号即可单独清除，并立刻重新查询。
  List<Widget> _buildFilterChips(BuildContext context) {
    final skin = EmbyPcSkin.of(context);
    Widget chip(String label, VoidCallback onDeleted) => InputChip(
      label: Text(label),
      onDeleted: _c.loading ? null : onDeleted,
      labelStyle: TextStyle(fontSize: 12, color: skin.scheme.onSurface),
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: skin.surfaceAlt.withValues(alpha: skin.dark ? 0.55 : 1),
      side: BorderSide(color: skin.hairline),
      deleteIcon: const Icon(Icons.close_rounded, size: 14),
      deleteIconColor: skin.textTertiary,
      shape: const StadiumBorder(),
    );
    final chips = <Widget>[];
    if (_c.itemType.isNotEmpty) {
      chips.add(
        chip(
          _itemTypeOptions[_c.itemType] ?? _c.itemType,
          () => _clearSimpleFilter('type'),
        ),
      );
    }
    if (_c.statusFilter.isNotEmpty) {
      chips.add(
        chip(
          _statusOptions[_c.statusFilter] ?? _c.statusFilter,
          () => _clearSimpleFilter('status'),
        ),
      );
    }
    if (_c.videoType.isNotEmpty) {
      chips.add(
        chip(
          _videoTypeOptions[_c.videoType] ?? _c.videoType,
          () => _clearSimpleFilter('videoType'),
        ),
      );
    }
    final year = _yearController.text.trim();
    if (year.isNotEmpty) {
      chips.add(chip('$year 年', () => _clearSimpleFilter('year')));
    }
    if (_c.genreFilter.isNotEmpty) {
      // 流派名来自懒加载的候选列表，未命中时退回通用文案。
      var genreName = '流派';
      for (final genre in _c.genreOptions) {
        if (genre.id == _c.genreFilter) {
          genreName = genre.name;
          break;
        }
      }
      chips.add(chip(genreName, () => _selectGenre('')));
    }
    if (_c.personFilter.isNotEmpty) {
      chips.add(
        chip('演员：${_c.personFilterName}', _clearPersonFilter),
      );
    }
    if (_c.minRating != null) {
      chips.add(
        chip(
          '${_c.minRating!.toStringAsFixed(0)} 分以上',
          () => _selectMinRating(null),
        ),
      );
    }
    return chips;
  }

  // 条件标签里的单值清除：类型 / 播放状态 / 视频格式 / 年份。
  void _clearSimpleFilter(String field) {
    setState(() {
      switch (field) {
        case 'type':
          _c.itemType = '';
        case 'status':
          _c.statusFilter = '';
        case 'videoType':
          _c.videoType = '';
        case 'year':
          _yearController.clear();
      }
    });
    unawaited(_applyQuery());
  }

  // 观看历史的极简工具栏：左侧说明固定排序，右侧沿用统一的条目统计。
  Widget _buildHistoryToolbar(
    BuildContext context, {
    required bool compact,
  }) {
    final skin = EmbyPcSkin.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 2, 16, 10)
          : const EdgeInsets.fromLTRB(28, 0, 28, 12),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 15, color: skin.textTertiary),
          const SizedBox(width: 6),
          Text(
            '按最近播放时间排序',
            style: TextStyle(fontSize: 12, color: skin.textTertiary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _pageStatusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: skin.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  int get _activeFilterCount => [
    _c.itemType,
    _c.statusFilter,
    _c.markFilter,
    _c.videoType,
    _yearController.text.trim(),
    _c.genreFilter,
    _c.personFilter,
    _c.minRating?.toString() ?? '',
  ].where((value) => value.isNotEmpty).length;

  // 搜索词同样会筛出空列表，空状态需要据此决定是否给出恢复入口。
  bool get _hasActiveFilters =>
      _activeFilterCount > 0 || _searchController.text.trim().isNotEmpty;

  Widget _buildFilterMenu(BuildContext context, {bool compact = false}) {
    final availableWidth = MediaQuery.sizeOf(context).width - 24;
    final panelWidth = availableWidth > 420 ? 420.0 : availableWidth;
    // 菜单内容左右各保留 14 像素内边距，选项宽度直接使用剩余空间计算。
    final contentWidth = panelWidth - 28;
    final showAdvancedFilters =
        _c.view != 'favorite-movies' &&
        _c.view != 'favorite-people' &&
        _c.view != 'watch-history';

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
                    options: _itemTypeOptions,
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
                      title: _c.genreOptions.isEmpty ? '流派（加载中…）' : '流派',
                      // 流派可能很多，只展示条目最多的前 12 个，避免面板过长。
                      options: {
                        '': '全部流派',
                        for (final genre in _c.genreOptions.take(12))
                          genre.id: genre.childCount == null
                              ? genre.name
                              : '${genre.name} ${genre.childCount}',
                      },
                      selected: _c.genreFilter,
                      availableWidth: contentWidth,
                      onSelected: _selectGenre,
                    ),
                    _buildQueryGroup(
                      title: '最低评分',
                      options: _ratingOptions,
                      selected: _c.minRating?.toInt().toString() ?? '',
                      availableWidth: contentWidth,
                      onSelected: (value) =>
                          _selectMinRating(double.tryParse(value)),
                    ),
                  ],
                  if (showAdvancedFilters) ...[
                    _buildQueryGroup(
                      title: '播放状态',
                      options: _statusOptions,
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
                          label: Text('演员：${_c.personFilterName}'),
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
      builder: (context, controller, child) => _buildQueryPill(
        label: _activeFilterCount == 0 ? '筛选' : '筛选 $_activeFilterCount',
        icon: Icons.filter_list,
        active: _activeFilterCount > 0,
        compact: compact,
        onPressed: _c.loading
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

  Widget _buildSortMenu(BuildContext context, {bool compact = false}) {
    // 演员没有评分/分辨率等影片字段，排序项改为人物资料属性。
    final peopleList = _c.view == 'people' || _c.view == 'favorite-people';
    const mediaSortOptions = {
      'CommunityRating': '评分',
      'Height': '分辨率',
      'DateCreated': '加入日期',
      'PremiereDate': '发行日期',
      'DatePlayed': '播放日期',
      'Runtime': '播放时长',
      'SortName': '文件名',
    };
    const peopleSortOptions = {
      'SortName': '名称',
      // 年龄由生日派生，升序即“从年轻到年长”。
      'Age': '年龄',
      'PremiereDate': '出道日期',
      'CupSize': '罩杯',
    };
    final sortOptions = peopleList ? peopleSortOptions : mediaSortOptions;
    final availableWidth = MediaQuery.sizeOf(context).width - 24;
    // 排序面板只有单列字段，宽度取窄一些，避免大面积空白。
    final panelWidth = availableWidth > 220 ? 220.0 : availableWidth;
    final colors = Theme.of(context).colorScheme;
    // 字段列表不是 MenuItemButton，选中后需要手动收起面板。
    final menuController = MenuController();

    return MenuAnchor(
      controller: menuController,
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
          // 只有一列字段，去掉标题后上下各留 8 像素即可。
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 字段列表只负责换字段，方向由工具栏按钮统一控制。
                ...sortOptions.entries.map((entry) {
                  final active = entry.key == _c.sortBy;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Semantics(
                      button: true,
                      selected: active,
                      excludeSemantics: true,
                      label: active
                          ? '${entry.value}，当前排序字段'
                          : '${entry.value}，点击按此字段排序',
                      child: Material(
                        color: active
                            ? colors.primary.withValues(alpha: 0.10)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          // 点击后立刻收起面板；已选中的字段只收起不重复查询。
                          onTap: _c.loading
                              ? null
                              : () {
                                  menuController.close();
                                  if (active) return;
                                  setState(() {
                                    // 手动指定排序即退出随机播放，回到常规列表。
                                    _c.exitRandomMode();
                                    _c.sortBy = entry.key;
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: active
                                                ? colors.primary
                                                : colors.onSurface,
                                            fontWeight: active
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                    ),
                                  ),
                                  if (active)
                                    Icon(
                                      Icons.check_rounded,
                                      size: 18,
                                      color: colors.primary,
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
      // 胶囊拆成两段：左箭头直接切升降序，右侧字段名展开字段列表。
      builder: (context, controller, child) => _buildSortPill(
        label: sortOptions[_c.sortBy] ?? '排序',
        compact: compact,
        onToggleOrder: _toggleSortOrder,
        onOpenMenu: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  // 排序胶囊：左侧箭头点击即切换升降序，右侧显示当前字段并展开字段列表。
  Widget _buildSortPill({
    required String label,
    required bool compact,
    required VoidCallback onToggleOrder,
    required VoidCallback onOpenMenu,
  }) {
    final skin = EmbyPcSkin.of(context);
    final enabled = !_c.loading;
    final ascending = _c.sortOrder == 'Ascending';
    final orderLabel = ascending ? '升序' : '降序';
    final textColor = enabled
        ? skin.scheme.onSurface
        : skin.textTertiary.withValues(alpha: 0.4);
    return Material(
      color: skin.surfaceAlt.withValues(alpha: skin.dark ? 0.55 : 1),
      shape: StadiumBorder(side: BorderSide(color: skin.hairline)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 38,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: enabled ? onOpenMenu : null,
              // 整段 38 高都可点，避免只有文字那一行能命中。
              child: SizedBox(
                height: 38,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(compact ? 10 : 14, 0, 6, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 17,
                        color: textColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 两段之间用发丝线分隔，点击区域互不干扰。
            Container(width: 1, height: 16, color: skin.hairline),
            // 升降序按钮固定在右侧，和字段名分开点击。
            Tooltip(
              message: '当前$orderLabel，点击切换',
              child: InkWell(
                onTap: enabled ? onToggleOrder : null,
                child: SizedBox(
                  width: compact ? 30 : 34,
                  height: 38,
                  child: Center(
                    child: Icon(
                      ascending
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 17,
                      color: textColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 升降序切换：与换字段一样退出随机模式并立即重查。
  void _toggleSortOrder() {
    if (_c.loading) return;
    _applySortOrder(_c.sortOrder == 'Ascending' ? 'Descending' : 'Ascending');
  }

  void _applySortOrder(String order) {
    if (_c.sortOrder == order) return;
    setState(() {
      _c.exitRandomMode();
      _c.sortOrder = order;
    });
    unawaited(_applyQuery());
  }

  // 随机播放：向服务端重新要一批随机条目（每次点按都换一批），并回到顶部。
  Future<void> _shuffleMediaItems() async {
    _syncQueryInput();
    await _c.shuffleItemsRandom();
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.minScrollExtent);
  }

  Widget _buildShuffleButton(
    BuildContext context, {
    required bool compact,
    required bool enabled,
  }) {
    final skin = EmbyPcSkin.of(context);
    final active = _c.randomMode;
    const tooltip = '随机播放：服务端重新抽取 50 条';
    final side = BorderSide(color: active ? skin.tint(0.5) : skin.hairline);
    final background = active
        ? skin.tint(0.16)
        : skin.surfaceAlt.withValues(alpha: skin.dark ? 0.55 : 1);
    if (compact) {
      // 移动端工具栏空间有限，只用图标，含义由 Tooltip 补充。
      return IconButton(
        tooltip: tooltip,
        onPressed: enabled ? () => unawaited(_shuffleMediaItems()) : null,
        style: IconButton.styleFrom(
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: active ? skin.accent : skin.scheme.onSurface,
          backgroundColor: background,
          side: side,
          shape: const StadiumBorder(),
        ),
        icon: const Icon(Icons.shuffle_rounded, size: 19),
      );
    }
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: enabled ? () => unawaited(_shuffleMediaItems()) : null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          foregroundColor: active ? skin.accent : skin.scheme.onSurface,
          backgroundColor: background,
          side: side,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        icon: const Icon(Icons.shuffle_rounded, size: 17),
        label: const Text('随机播放'),
      ),
    );
  }

  Widget _buildLayoutControl(BuildContext context, {required bool compact}) {
    final skin = EmbyPcSkin.of(context);
    return SegmentedButton<String>(
      showSelectedIcon: false,
      segments: compact
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
      onSelectionChanged: _c.loading
          ? null
          : (selection) => _updateImageStyle(selection.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        // 布局选中态与侧栏、筛选项统一使用用户设置的主题色。
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? skin.scheme.onPrimary
              : skin.textSecondary,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? skin.scheme.onPrimary
              : skin.textSecondary,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? skin.accent
              : skin.surfaceAlt.withValues(alpha: skin.dark ? 0.55 : 1),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: skin.hairline)),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
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
      children: options.entries.map((entry) {
        final active = entry.key == selected;
        return SizedBox(
          width: itemWidth,
          child: OutlinedButton(
            onPressed: _c.loading ? null : () => onSelected(entry.key),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              alignment: Alignment.centerLeft,
              foregroundColor: active ? colors.primary : colors.onSurface,
              backgroundColor: active
                  ? colors.primary.withValues(alpha: 0.12)
                  : null,
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
    final skin = EmbyPcSkin.of(context);
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 38),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      foregroundColor: active ? skin.accent : skin.scheme.onSurface,
      backgroundColor: active
          ? skin.tint(0.16)
          : skin.surfaceAlt.withValues(alpha: skin.dark ? 0.55 : 1),
      side: BorderSide(color: active ? skin.tint(0.5) : skin.hairline),
      shape: const StadiumBorder(),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: 4),
        const Icon(Icons.keyboard_arrow_down_rounded, size: 17),
      ],
    );
    if (compact) {
      // 移动端保留明确的文字入口，省略重复图标以释放横向空间。
      return OutlinedButton(onPressed: onPressed, style: style, child: content);
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 17),
      label: content,
    );
  }
}
