part of 'emby_pc_page.dart';

// 搜索状态保留在浮层内部，关闭后不会污染首页或媒体库列表查询。
class _GlobalSearchDialog extends StatefulWidget {
  const _GlobalSearchDialog();

  @override
  State<_GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends State<_GlobalSearchDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  List<EmbyPcItem> _items = const [];
  int _total = 0;
  int _requestVersion = 0;
  bool _loading = false;
  String _error = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scheduleSearch(String value) => _startSearch(value, debounce: true);

  void _startSearch(String value, {bool debounce = false}) {
    _debounce?.cancel();
    final query = value.trim();
    final version = ++_requestVersion;
    setState(() {
      _items = const [];
      _total = 0;
      _error = '';
      _loading = query.isNotEmpty;
    });
    if (query.isEmpty) return;
    if (!debounce) {
      _loadSearch(query, version);
      return;
    }
    // 浮层内同样使用短防抖，连续输入时只保留最后一次有效请求。
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _loadSearch(query, version),
    );
  }

  Future<void> _loadSearch(String query, int version) async {
    try {
      final page = await EmbyPcService.instance.searchItems(query);
      if (!mounted ||
          version != _requestVersion ||
          _controller.text.trim() != query) {
        return;
      }
      setState(() {
        _items = page.items;
        _total = page.total;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _requestVersion++;
    setState(() {
      _controller.clear();
      _items = const [];
      _total = 0;
      _loading = false;
      _error = '';
    });
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasQuery = _controller.text.trim().isNotEmpty;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape):
            () => Navigator.of(context).maybePop(),
      },
      child: AnimatedContainer(
        duration:
            reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: double.infinity,
        height: hasQuery ? 560 : 78,
        child: Material(
          color: colors.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 24,
          shadowColor: colors.shadow.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
                child: Row(
                  children: [
                    Expanded(child: _buildSearchField(context)),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '关闭搜索',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              if (hasQuery) ...[
                Divider(height: 1, color: colors.outlineVariant),
                Expanded(child: _buildBody(context)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: _scheduleSearch,
        onSubmitted: _startSearch,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: colors.surfaceContainerLow,
          hintText: '搜索电影、剧集、视频和演员',
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon:
              _loading
                  ? const Center(
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                  : _controller.text.trim().isEmpty
                  ? null
                  : IconButton(
                    tooltip: '清除搜索',
                    onPressed: _clearSearch,
                    icon: const Icon(Icons.clear_rounded, size: 18),
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

  Widget _buildBody(BuildContext context) {
    final query = _controller.text.trim();
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return _GlobalSearchMessage(
        icon: Icons.error_outline_rounded,
        title: '搜索失败',
        subtitle: _error,
        actionLabel: '重试',
        onAction: () => _startSearch(query),
      );
    }
    if (_items.isEmpty) {
      return _GlobalSearchMessage(
        icon: Icons.search_off_rounded,
        title: '没有找到“$query”',
        subtitle: '请尝试更短的关键词，或检查名称',
      );
    }

    final media = _items.where((item) => item.type != 'Person').toList();
    final people = _items.where((item) => item.type == 'Person').toList();
    return CustomScrollView(
      slivers: [
        ..._buildResultSection('影视内容', media),
        ..._buildResultSection('演员', people),
        if (_total > _items.length)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
              child: Text(
                '共 $_total 项，当前展示前 ${_items.length} 项',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
          )
        else
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  List<Widget> _buildResultSection(String title, List<EmbyPcItem> items) {
    if (items.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Text(
            '$title  ${items.length}',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _GlobalSearchListTile(
              item: item,
              onPressed: () => Navigator.of(context).pop(item),
            );
          },
        ),
      ),
    ];
  }
}

class _GlobalSearchMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _GlobalSearchMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GlobalSearchListTile extends StatelessWidget {
  final EmbyPcItem item;
  final VoidCallback onPressed;

  const _GlobalSearchListTile({required this.item, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isPerson = item.type == 'Person';
    final useBackdrop = !isPerson && item.hasBackdropImage;
    final hasImage = useBackdrop ? item.hasBackdropImage : item.hasPrimaryImage;
    final imageUrl =
        hasImage
            ? EmbyPcService.instance.imageUrl(
              item.id,
              type: useBackdrop ? 'Backdrop' : 'Primary',
              maxWidth: useBackdrop ? 260 : 140,
            )
            : '';
    final metadata = <String>[
      _typeLabel(item.type),
      if (item.productionYear != null) '${item.productionYear}',
      if (item.communityRating != null)
        '评分 ${item.communityRating!.toStringAsFixed(1)}',
    ].where((value) => value.isNotEmpty).join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: ListTile(
        onTap: onPressed,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minVerticalPadding: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        hoverColor: colors.primary.withValues(alpha: 0.07),
        leading: SizedBox(
          width: isPerson ? 54 : 92,
          height: 54,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: EmbyPcNetworkImage(url: imageUrl),
          ),
        ),
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          metadata,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          size: 20,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
    'Movie' => '电影',
    'Series' => '剧集',
    'Video' => '视频',
    'Person' => '演员',
    _ => type,
  };
}

