part of 'emby_pc_page.dart';

enum _LibraryAction { editImages, scan, refreshMetadata }

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
            color: active
                ? colors.primary.withValues(alpha: 0.11)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: collapsed
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
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
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
  final bool busy;
  final VoidCallback onPressed;
  final ValueChanged<_LibraryAction> onAction;

  const _HomeLibraryTile({
    required this.library,
    required this.busy,
    required this.onPressed,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final imageUrl = EmbyPcService.instance.imageUrl(
      library.id,
      type: 'Primary',
      maxWidth: 640,
      cacheKey: library.primaryImageTag.isNotEmpty
          ? library.primaryImageTag
          : library.imageTags['Primary']?.toString() ?? '',
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
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
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: PopupMenuButton<_LibraryAction>(
                          enabled: !busy,
                          tooltip: '媒体库操作',
                          onSelected: onAction,
                          constraints: const BoxConstraints.tightFor(
                            width: 38,
                            height: 38,
                          ),
                          padding: EdgeInsets.zero,
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: _LibraryAction.editImages,
                              child: _LibraryMenuEntry(
                                icon: Icons.image_outlined,
                                label: '编辑图像',
                              ),
                            ),
                            PopupMenuItem(
                              value: _LibraryAction.scan,
                              child: _LibraryMenuEntry(
                                icon: Icons.manage_search_outlined,
                                label: '扫描媒体库',
                              ),
                            ),
                            PopupMenuItem(
                              value: _LibraryAction.refreshMetadata,
                              child: _LibraryMenuEntry(
                                icon: Icons.refresh_outlined,
                                label: '刷新元数据',
                              ),
                            ),
                          ],
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest.withValues(
                                alpha: 0.94,
                              ),
                              shape: BoxShape.circle,
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x24000000),
                                  blurRadius: 5,
                                ),
                              ],
                            ),
                            child: Center(
                              child: busy
                                  ? const SizedBox.square(
                                      dimension: 17,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.more_horiz, size: 23),
                            ),
                          ),
                        ),
                      ),
                    ],
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

class _LibraryMenuEntry extends StatelessWidget {
  final IconData icon;
  final String label;

  const _LibraryMenuEntry({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
  );
}

class _MetadataRefreshOptions {
  final String mode;
  final bool replaceImages;
  final bool replaceThumbnailImages;

  const _MetadataRefreshOptions({
    required this.mode,
    required this.replaceImages,
    required this.replaceThumbnailImages,
  });
}

class _MetadataRefreshDialog extends StatefulWidget {
  final String name;

  const _MetadataRefreshDialog({required this.name});

  @override
  State<_MetadataRefreshDialog> createState() => _MetadataRefreshDialogState();
}

class _MetadataRefreshDialogState extends State<_MetadataRefreshDialog> {
  String _mode = 'Default';
  bool _replaceImages = false;
  bool _replaceThumbnailImages = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('刷新元数据 · ${widget.name}'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: '刷新模式',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'Default', child: Text('搜索缺少的元数据')),
              DropdownMenuItem(value: 'FullRefresh', child: Text('替换所有元数据')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _mode = value);
            },
          ),
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('替换现有图像'),
            subtitle: const Text('删除现有图像，并根据媒体库选项重新下载。'),
            value: _replaceImages,
            onChanged: (value) => setState(() => _replaceImages = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('替换现有视频预览缩略图'),
            subtitle: const Text('删除已有视频预览缩略图并重新生成。'),
            value: _replaceThumbnailImages,
            onChanged: (value) =>
                setState(() => _replaceThumbnailImages = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.pop(
          context,
          _MetadataRefreshOptions(
            mode: _mode,
            replaceImages: _replaceImages,
            replaceThumbnailImages: _replaceThumbnailImages,
          ),
        ),
        icon: const Icon(Icons.refresh, size: 19),
        label: const Text('刷新'),
      ),
    ],
  );
}

class _LibraryImageSlot {
  final String type;
  final String label;

  const _LibraryImageSlot(this.type, this.label);
}

const _libraryImageSlots = [
  _LibraryImageSlot('Primary', '海报'),
  _LibraryImageSlot('Logo', '徽标'),
  _LibraryImageSlot('Thumb', '缩略图'),
  _LibraryImageSlot('Banner', '横幅图'),
  _LibraryImageSlot('Disc', '光盘封面'),
  _LibraryImageSlot('Art', '艺术图'),
  _LibraryImageSlot('Backdrop', '背景图'),
];

class _LibraryImagesDialog extends StatefulWidget {
  final EmbyPcItem library;

  const _LibraryImagesDialog({required this.library});

  @override
  State<_LibraryImagesDialog> createState() => _LibraryImagesDialogState();
}

class _LibraryImagesDialogState extends State<_LibraryImagesDialog> {
  List<EmbyPcImageInfo> _images = const [];
  final Set<String> _busyTypes = {};
  bool _loading = true;
  bool _changed = false;
  int _imageRevision = 0;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages({bool showProgress = true}) async {
    if (showProgress && mounted) setState(() => _loading = true);
    try {
      final images = await EmbyPcService.instance.getItemImages(
        widget.library.id,
      );
      if (!mounted) return;
      setState(() {
        _images = images;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage(error.toString());
    }
  }

  EmbyPcImageInfo? _imageFor(String type) {
    for (final image in _images) {
      if (image.type == type) return image;
    }
    return null;
  }

  Future<void> _upload(
    _LibraryImageSlot slot,
    EmbyPcImageInfo? currentImage,
  ) async {
    if (_busyTypes.contains(slot.type)) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _showMessage('无法读取所选图片');
      return;
    }

    setState(() => _busyTypes.add(slot.type));
    try {
      await EmbyPcService.instance.uploadItemImage(
        widget.library.id,
        type: slot.type,
        index: currentImage?.index,
        bytes: bytes,
        contentType: _imageContentType(file.extension),
      );
      _changed = true;
      _imageRevision++;
      await _loadImages(showProgress: false);
      if (mounted) _showMessage('${slot.label}上传成功');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busyTypes.remove(slot.type));
    }
  }

  Future<void> _delete(_LibraryImageSlot slot, EmbyPcImageInfo image) async {
    if (_busyTypes.contains(slot.type)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除${slot.label}？'),
        content: const Text('删除后无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyTypes.add(slot.type));
    try {
      await EmbyPcService.instance.deleteItemImage(
        widget.library.id,
        type: image.type,
        index: image.index,
      );
      _changed = true;
      _imageRevision++;
      await _loadImages(showProgress: false);
      if (mounted) _showMessage('${slot.label}已删除');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busyTypes.remove(slot.type));
    }
  }

  String _imageContentType(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      default:
        return 'image/jpeg';
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 32).clamp(300.0, 1000.0).toDouble();
    final dialogHeight = (size.height - 32).clamp(420.0, 760.0).toDouble();
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 20, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context, _changed),
                    icon: const Icon(Icons.close),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '编辑图像 · ${widget.library.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : GridView.builder(
                      padding: const EdgeInsets.all(20),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 230,
                            mainAxisExtent: 224,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                      itemCount: _libraryImageSlots.length,
                      itemBuilder: (context, index) {
                        final slot = _libraryImageSlots[index];
                        return _buildImageSlot(slot, _imageFor(slot.type));
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSlot(_LibraryImageSlot slot, EmbyPcImageInfo? image) {
    final colors = Theme.of(context).colorScheme;
    final busy = _busyTypes.contains(slot.type);
    final imageUrl = image == null
        ? ''
        : EmbyPcService.instance.imageUrl(
            widget.library.id,
            type: image.type,
            index: image.index,
            maxWidth: 520,
            cacheKey: '$_imageRevision',
          );
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: image == null
                ? Center(
                    child: Icon(
                      Icons.image_outlined,
                      size: 36,
                      color: colors.onSurfaceVariant,
                    ),
                  )
                : EmbyPcNetworkImage(url: imageUrl),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 6, 7),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slot.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (image?.dimensions.isNotEmpty == true)
                        Text(
                          image!.dimensions,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...[
                  IconButton(
                    tooltip: image == null
                        ? '上传${slot.label}'
                        : '替换${slot.label}',
                    onPressed: () => _upload(slot, image),
                    icon: Icon(
                      image == null
                          ? Icons.add_circle_outline
                          : Icons.upload_outlined,
                    ),
                  ),
                  if (image != null)
                    IconButton(
                      tooltip: '删除${slot.label}',
                      onPressed: () => _delete(slot, image),
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ],
            ),
          ),
        ],
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
        child: _libraries.isEmpty
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
                itemBuilder: (context, index) => ListTile(
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
