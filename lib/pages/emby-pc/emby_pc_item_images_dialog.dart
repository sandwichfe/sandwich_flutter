import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';
import 'emby_pc_widgets.dart';

class _ItemImageSlot {
  final String type;
  final String label;

  const _ItemImageSlot(this.type, this.label);
}

const _itemImageSlots = [
  _ItemImageSlot('Primary', '海报'),
  _ItemImageSlot('Logo', '徽标'),
  _ItemImageSlot('Thumb', '缩略图'),
  _ItemImageSlot('Banner', '横幅图'),
  _ItemImageSlot('Disc', '光盘封面'),
  _ItemImageSlot('Art', '艺术图'),
];

// Emby 允许同一项目保存多张背景图，不能像其他类型一样压缩成单个槽位。
const _backdropImageSlot = _ItemImageSlot('Backdrop', '背景图');

// 媒体列表和人物详情共用同一个图像编辑器，确保上传、替换和删除行为一致。
class EmbyPcItemImagesDialog extends StatefulWidget {
  final EmbyPcItem item;

  const EmbyPcItemImagesDialog({super.key, required this.item});

  @override
  State<EmbyPcItemImagesDialog> createState() => _EmbyPcItemImagesDialogState();
}

class _EmbyPcItemImagesDialogState extends State<EmbyPcItemImagesDialog> {
  List<EmbyPcImageInfo> _images = const [];
  final Set<String> _busyTypes = {};
  bool _loading = true;
  bool _changed = false;
  int _imageRevision = 0;

  @override
  void initState() {
    super.initState();
    // 图像列表仅在用户打开编辑弹窗时按需获取。
    _loadImages();
  }

  Future<void> _loadImages({bool showProgress = true}) async {
    if (showProgress && mounted) setState(() => _loading = true);
    try {
      final images = await EmbyPcService.instance.getItemImages(widget.item.id);
      if (!mounted) return;
      setState(() {
        _images = images;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage(error.toString(), type: EmbyPcToastType.error);
    }
  }

  EmbyPcImageInfo? _imageFor(String type) {
    for (final image in _images) {
      if (image.type == type) return image;
    }
    return null;
  }

  List<EmbyPcImageInfo> _imagesFor(String type) {
    final images = _images.where((image) => image.type == type).toList();
    images.sort((a, b) => a.index.compareTo(b.index));
    return images;
  }

  Future<void> _upload(
    _ItemImageSlot slot,
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
      _showMessage('无法读取所选图片', type: EmbyPcToastType.error);
      return;
    }

    setState(() => _busyTypes.add(slot.type));
    try {
      await EmbyPcService.instance.uploadItemImage(
        widget.item.id,
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
      if (mounted) _showMessage(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _busyTypes.remove(slot.type));
    }
  }

  Future<void> _delete(_ItemImageSlot slot, EmbyPcImageInfo image) async {
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
        widget.item.id,
        type: image.type,
        index: image.index,
      );
      _changed = true;
      _imageRevision++;
      await _loadImages(showProgress: false);
      if (mounted) _showMessage('${slot.label}已删除');
    } catch (error) {
      if (mounted) _showMessage(error.toString(), type: EmbyPcToastType.error);
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

  void _showMessage(
    String message, {
    EmbyPcToastType type = EmbyPcToastType.success,
  }) {
    EmbyPcToast.show(context, message, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 32).clamp(300.0, 1000.0).toDouble();
    final dialogHeight = (size.height - 32).clamp(420.0, 760.0).toDouble();
    final backdropImages = _imagesFor(_backdropImageSlot.type);
    const gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 230,
      mainAxisExtent: 224,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
    );
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
                      '编辑图像 · ${widget.item.name}',
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
                  : CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                          sliver: SliverGrid.builder(
                            gridDelegate: gridDelegate,
                            itemCount: _itemImageSlots.length,
                            itemBuilder: (context, index) {
                              final slot = _itemImageSlots[index];
                              return _buildImageSlot(
                                slot,
                                _imageFor(slot.type),
                              );
                            },
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                          sliver: SliverToBoxAdapter(
                            child: Text(
                              _backdropImageSlot.label,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          sliver: SliverGrid.builder(
                            gridDelegate: gridDelegate,
                            itemCount: backdropImages.length + 1,
                            itemBuilder: (context, index) {
                              if (index == backdropImages.length) {
                                return _buildAddBackdropSlot();
                              }
                              final image = backdropImages[index];
                              final title = image.fileName.trim().isEmpty
                                  ? '${_backdropImageSlot.label} ${index + 1}'
                                  : image.fileName;
                              return _buildImageSlot(
                                _backdropImageSlot,
                                image,
                                title: title,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // 新增入口作为背景图列表的最后一格，位置不会随图片数量变化而产生歧义。
  Widget _buildAddBackdropSlot() {
    final colors = Theme.of(context).colorScheme;
    final busy = _busyTypes.contains(_backdropImageSlot.type);
    return Semantics(
      button: true,
      enabled: !busy,
      label: '添加背景图',
      child: Material(
        color: colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : () => _upload(_backdropImageSlot, null),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.add, size: 30, color: colors.primary),
                ),
                const SizedBox(height: 12),
                Text(
                  busy ? '处理中...' : '添加背景图',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageSlot(
    _ItemImageSlot slot,
    EmbyPcImageInfo? image, {
    String? title,
  }) {
    final colors = Theme.of(context).colorScheme;
    final busy = _busyTypes.contains(slot.type);
    final imageUrl = image == null
        ? ''
        : EmbyPcService.instance.imageUrl(
            widget.item.id,
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
                        title ?? slot.label,
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
