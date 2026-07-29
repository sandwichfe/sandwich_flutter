part of 'emby_pc_page.dart';

// 工作台内部使用的导航项、排序弹窗和状态视图。
class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final int? count;
  final bool showCount;
  final bool active;
  final bool loading;
  final bool collapsed;
  final VoidCallback onPressed;

  const _SidebarButton({
    required this.icon,
    required this.title,
    required this.count,
    this.showCount = true,
    required this.active,
    this.loading = false,
    this.collapsed = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final button = Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Stack(
        children: [
          Material(
            color:
                active
                    ? colors.primary.withValues(alpha: 0.11)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment:
                      collapsed
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                  children: [
                    SizedBox(width: collapsed ? 0 : 14),
                    Icon(
                      icon,
                      size: 20,
                      color: active ? colors.primary : colors.onSurfaceVariant,
                    ),
                    if (!collapsed) ...[
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // 侧栏文字固定使用微软雅黑 UI，避免中英文混用不同字体。
                            fontFamily: 'Microsoft YaHei UI',
                            fontSize: 14,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (loading)
                        const SizedBox.square(
                          dimension: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (showCount)
                        Container(
                          constraints: const BoxConstraints(minWidth: 24),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.onSurface.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            count == null ? '-' : '$count',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontFamily: 'Microsoft YaHei UI',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      const SizedBox(width: 11),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (active)
            Positioned(
              left: 0,
              top: 9,
              bottom: 9,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
    return collapsed ? Tooltip(message: title, child: button) : button;
  }
}

// 首页媒体库使用横向封面入口，点击后仍复用现有媒体库详情加载逻辑。
class _HomeLibraryTile extends StatelessWidget {
  final EmbyPcItem library;
  final VoidCallback onPressed;

  const _HomeLibraryTile({required this.library, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final imageUrl = EmbyPcService.instance.imageUrl(
      library.id,
      type: 'Primary',
      maxWidth: 640,
    );
    return SizedBox(
      width: 246,
      child: Semantics(
        button: true,
        label: '打开媒体库 ${library.name}',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: EmbyPcNetworkImage(
                        url: library.hasPrimaryImage ? imageUrl : '',
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 9, 4, 3),
                  child: Text(
                    library.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarSectionTitle extends StatelessWidget {
  final String title;

  const _SidebarSectionTitle(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
    child: Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFamily: 'Microsoft YaHei UI',
        fontSize: 12,
        // 小字号使用中等字重，避免微软雅黑 UI 的笔画显得拥挤。
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

class _LibraryOrderDialog extends StatefulWidget {
  final List<EmbyPcItem> libraries;

  const _LibraryOrderDialog({required this.libraries});

  @override
  State<_LibraryOrderDialog> createState() => _LibraryOrderDialogState();
}

class _LibraryOrderDialogState extends State<_LibraryOrderDialog> {
  late final List<EmbyPcItem> _libraries = List.of(widget.libraries);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('调整媒体库顺序'),
    content: SizedBox(
      width: 420,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 500),
        child:
            _libraries.isEmpty
                ? const Text('暂无媒体库')
                : ReorderableListView.builder(
                  shrinkWrap: true,
                  itemCount: _libraries.length,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final item = _libraries.removeAt(oldIndex);
                      _libraries.insert(newIndex, item);
                    });
                  },
                  itemBuilder:
                      (context, index) => ListTile(
                        key: ValueKey(_libraries[index].id),
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(_libraries[index].name),
                        trailing: const Icon(Icons.drag_handle),
                      ),
                ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _libraries),
        child: const Text('保存'),
      ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.movie_filter_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        const Text('没有找到媒体'),
      ],
    ),
  );
}

class _WorkspaceError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _WorkspaceError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 52),
        const SizedBox(height: 12),
        Text(message),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}
