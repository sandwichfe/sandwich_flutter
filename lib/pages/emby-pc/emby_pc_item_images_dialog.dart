import 'dart:async';

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
  bool _generating = false;
  int _imageRevision = 0;

  // 图片锁：锁上后扫描导入与自动重拼不会覆盖，手动操作不受影响。
  bool _locked = false;
  bool _lockBusy = false;

  // 只有视频条目能从画面抽帧生成图片（剧集、媒体库等没有可抽帧的文件）。
  bool get _canGenerateArtwork =>
      widget.item.type.isNotEmpty &&
      const {'Movie', 'Video', 'Episode'}.contains(widget.item.type);

  @override
  void initState() {
    super.initState();
    // 图像列表仅在用户打开编辑弹窗时按需获取。
    _loadImages();
    _loadLock();
  }

  Future<void> _loadLock() async {
    try {
      final locked = await EmbyPcService.instance.getItemImagesLocked(
        widget.item.id,
      );
      if (mounted) setState(() => _locked = locked);
    } catch (_) {
      // 锁状态读不到时不阻塞编辑，按未锁定处理。
    }
  }

  Future<void> _toggleLock() async {
    if (_lockBusy) return;
    final target = !_locked;
    setState(() => _lockBusy = true);
    try {
      final locked = await EmbyPcService.instance.setItemImagesLocked(
        widget.item.id,
        target,
      );
      if (!mounted) return;
      setState(() => _locked = locked);
      _showMessage(
        locked ? '已锁定，扫描不会覆盖这些图片' : '已解锁，扫描时可以更新这些图片',
      );
    } catch (error) {
      if (mounted) _showMessage(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _lockBusy = false);
    }
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

  // 一个槽位只有一张图，主槽位取该类型第一张，背景图列表按同一顺序展示。
  EmbyPcImageInfo? _imageFor(String type) {
    final matches = _imagesFor(type);
    return matches.isEmpty ? null : matches.first;
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

  // 从视频画面生成海报/封面：可选自动嗅探，或指定一个进度点。
  Future<void> _generateArtwork() async {
    final options = await showDialog<_ArtworkGenerateOptions>(
      context: context,
      builder: (context) => _ArtworkGenerateDialog(item: widget.item),
    );
    if (options == null || !mounted) return;

    setState(() => _generating = true);
    try {
      final result = await EmbyPcService.instance.generateArtwork(
        widget.item.id,
        sniff: options.sniff,
        positionTicks: options.positionTicks,
        types: options.types,
      );
      _changed = true;
      _imageRevision++;
      await _loadImages(showProgress: false);
      if (!mounted) return;
      final position = _formatTicks(result.positionTicks);
      _showMessage(
        result.sniffed ? '已自动嗅探画面并生成图片（$position）' : '已生成图片（$position）',
      );
    } catch (error) {
      if (mounted) _showMessage(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  String _formatTicks(int ticks) {
    if (ticks <= 0) return '00:00';
    final totalSeconds = Duration(microseconds: ticks ~/ 10).inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return hours > 0
        ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
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
                  IconButton(
                    tooltip: _locked
                        ? '已锁定：扫描不会覆盖这些图片'
                        : '锁定图片，扫描时不覆盖',
                    onPressed: _lockBusy ? null : _toggleLock,
                    icon: _lockBusy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _locked ? Icons.lock : Icons.lock_open_outlined,
                            color: _locked
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                  ),
                  if (_canGenerateArtwork)
                    _generating
                        ? const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            tooltip: '从视频画面生成海报/封面',
                            onPressed: _generateArtwork,
                            icon: const Icon(Icons.auto_awesome_outlined),
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
                              // 背景图可以有多张，有文件名就显示文件名，否则用序号。
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

// 生成封面时用户选择的取帧方式与输出类型。
class _ArtworkGenerateOptions {
  final bool sniff;
  final int positionTicks;
  final List<String> types;

  const _ArtworkGenerateOptions({
    required this.sniff,
    required this.positionTicks,
    required this.types,
  });
}

// 默认自动嗅探；关掉嗅探后可用滑块指定进度点取帧。
class _ArtworkGenerateDialog extends StatefulWidget {
  final EmbyPcItem item;

  const _ArtworkGenerateDialog({required this.item});

  @override
  State<_ArtworkGenerateDialog> createState() => _ArtworkGenerateDialogState();
}

class _ArtworkGenerateDialogState extends State<_ArtworkGenerateDialog> {
  bool _sniff = true;
  // 默认取 30% 处，避开片头黑场与字幕。
  double _percent = 0.30;
  bool _primary = true;
  bool _backdrop = true;

  // 取帧预览：拖动滑块时按进度点向服务端要一帧画面。
  Timer? _previewTimer;
  String _previewUrl = '';
  int _previewTicks = -1;

  // 前端拿不到时长时无法给出进度点，只能走自动嗅探。
  bool get _hasDuration => widget.item.runTimeTicks > 0;
  bool get _effectiveSniff => _sniff || !_hasDuration;

  int get _positionTicks => (widget.item.runTimeTicks * _percent).round();

  String get _positionLabel {
    final totalSeconds = (_positionTicks / 10000000).round();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return hours > 0
        ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  List<String> get _types => [
    if (_primary) 'Primary',
    if (_backdrop) 'Backdrop',
  ];

  @override
  void dispose() {
    _previewTimer?.cancel();
    super.dispose();
  }

  // 拖动过程中只在停手一小会儿后取帧，松手时立刻刷新：
  // 既不会每移动一格就打一次 ffmpeg，也不会觉得预览慢半拍。
  void _schedulePreview({bool immediate = false}) {
    if (_effectiveSniff) return;
    _previewTimer?.cancel();
    if (immediate) {
      _refreshPreview();
      return;
    }
    _previewTimer = Timer(const Duration(milliseconds: 180), _refreshPreview);
  }

  void _refreshPreview() {
    if (!mounted || _effectiveSniff) return;
    final ticks = _positionTicks;
    // 同一进度点的画面是一致的，拖回去时直接复用缓存，不重复抽帧。
    if (ticks == _previewTicks && _previewUrl.isNotEmpty) return;
    setState(() {
      _previewTicks = ticks;
      _previewUrl = EmbyPcService.instance.framePreviewUrl(
        widget.item.id,
        positionTicks: ticks,
      );
    });
  }

  void _toggleSniff(bool value) {
    // 打开自动嗅探时收起预览；关掉后立刻给出一帧，避免先看到空白。
    _previewTimer?.cancel();
    setState(() {
      _sniff = value;
      if (value) {
        _previewUrl = '';
        _previewTicks = -1;
      }
    });
    if (!value) _schedulePreview(immediate: true);
  }

  void _confirm() {
    Navigator.pop(
      context,
      _ArtworkGenerateOptions(
        sniff: _effectiveSniff,
        positionTicks: _effectiveSniff ? 0 : _positionTicks,
        types: _types,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('生成海报与封面 · ${widget.item.name}', maxLines: 1),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动嗅探画面'),
                subtitle: Text(
                  _hasDuration
                      ? '在片长中段抽样若干帧，自动选择画面最清晰的一帧'
                      : '缺少片长信息，只能自动嗅探画面',
                ),
                value: _effectiveSniff,
                onChanged: _hasDuration ? _toggleSniff : null,
              ),
              if (!_effectiveSniff) ...[
                const SizedBox(height: 4),
                _FramePreview(
                  url: _previewUrl,
                  positionLabel: _positionLabel,
                  // 海报是 2:3，画面上标出居中裁切范围，选帧时就能看到最终构图。
                  showPosterGuide: _primary,
                ),
                const SizedBox(height: 8),
                Slider(
                  value: _percent,
                  min: 0.02,
                  max: 0.98,
                  divisions: 96,
                  label: _positionLabel,
                  onChanged: (value) {
                    setState(() => _percent = value);
                    _schedulePreview();
                  },
                  onChangeEnd: (_) => _schedulePreview(immediate: true),
                ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('生成海报'),
                subtitle: const Text('竖版 2:3'),
                value: _primary,
                onChanged: (value) => setState(() => _primary = value ?? false),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('生成封面'),
                subtitle: const Text('横版 16:9'),
                value: _backdrop,
                onChanged: (value) => setState(() => _backdrop = value ?? false),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _types.isEmpty ? null : _confirm,
          // 手动选帧时明确告诉用户确认动作就是"用这一帧"。
          child: Text(_effectiveSniff ? '生成' : '用这一帧生成'),
        ),
      ],
    );
  }
}

// 取帧预览框：拖动滑块时实时显示服务端抽出的那一帧。
// 单独用 Image.network 而不用全局的 CachedNetworkImage：滑动会连续产生大量地址，
// 这些临时画面不该写进海报的磁盘缓存，留在内存 ImageCache 里就够。
class _FramePreview extends StatelessWidget {
  final String url;
  final String positionLabel;
  final bool showPosterGuide;

  const _FramePreview({
    required this.url,
    required this.positionLabel,
    required this.showPosterGuide,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: colors.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url.isEmpty)
                Center(
                  child: Text(
                    '拖动下方滑块预览这一帧',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                Image.network(
                  url,
                  fit: BoxFit.cover,
                  // 换帧期间保留上一张，拖动过程不会黑屏闪烁。
                  gaplessPlayback: true,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        child,
                        Center(
                          child: SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ],
                    );
                  },
                  errorBuilder: (context, error, stackTrace) => Center(
                    child: Text(
                      '这一帧取不到画面，换个位置试试',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              // 海报是竖版 2:3：在 16:9 画面上框出居中裁切区，
              // 拖动选帧时看到的就是生成后的构图，而不是播放器的整幅画面。
              if (url.isNotEmpty && showPosterGuide)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.center,
                      child: FractionallySizedBox(
                        widthFactor: 0.375,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white70),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (url.isNotEmpty && showPosterGuide)
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      child: Text(
                        '竖框内为海报画面',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              if (url.isNotEmpty)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Text(
                        positionLabel,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
