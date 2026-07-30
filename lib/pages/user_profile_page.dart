import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_image/crop_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'emby-pc/emby_pc_service.dart';

class UserProfilePage extends StatefulWidget {
  const UserProfilePage({super.key});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  bool _uploading = false;

  Future<void> _chooseAvatar() async {
    if (_uploading) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _showMessage('无法读取所选图片');
      return;
    }

    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => _AvatarCropPage(image: bytes)),
    );
    if (cropped == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      await EmbyPcService.instance.uploadUserAvatar(
        bytes: cropped,
        // 裁剪器固定输出 PNG，上传类型必须和实际图片编码保持一致。
        contentType: 'image/png',
      );
      if (!mounted) return;
      setState(() {});
      _showMessage('头像已更新');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final service = EmbyPcService.instance;
    final colors = Theme.of(context).colorScheme;
    final userName = service.currentUserName.trim();
    return Scaffold(
      appBar: AppBar(title: const Text('用户信息')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        children: [
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 56,
                  backgroundColor: colors.surfaceContainerHighest,
                  foregroundImage: NetworkImage(
                    service.userAvatarUrl(maxWidth: 224),
                  ),
                  onForegroundImageError: (_, _) {},
                  child: Icon(
                    Icons.person_outline,
                    size: 48,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: IconButton.filled(
                    tooltip: '选择头像',
                    onPressed: _uploading ? null : _chooseAvatar,
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            userName.isEmpty ? '当前用户' : userName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            service.serverUrl,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          Center(
            child: FilledButton.icon(
              onPressed: _uploading ? null : _chooseAvatar,
              icon: _uploading
                  ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.upload_outlined),
              label: Text(_uploading ? '上传中' : '选择并裁剪头像'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvatarCropPage extends StatefulWidget {
  final Uint8List image;

  const _AvatarCropPage({required this.image});

  @override
  State<_AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<_AvatarCropPage> {
  final _controller = CropController(
    aspectRatio: 1,
    defaultCrop: const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9),
  );
  bool _cropping = false;

  Future<void> _crop() async {
    if (_cropping) return;
    setState(() => _cropping = true);
    try {
      final bitmap = await _controller.croppedBitmap(maxSize: 1024);
      final data = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      bitmap.dispose();
      if (data == null) throw StateError('无法生成裁剪图片');
      if (!mounted) return;
      Navigator.of(context).pop(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _cropping = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('裁剪失败：$error')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('裁剪头像'),
        actions: [
          IconButton(
            tooltip: '完成裁剪',
            onPressed: _cropping ? null : _crop,
            icon: _cropping
                ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.check),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CropImage(
            controller: _controller,
            image: Image.memory(widget.image),
            // 头像裁剪比例固定为 1:1，拖动边角即可调整最终构图。
            gridColor: colors.onSurface,
            gridInnerColor: colors.onSurface.withValues(alpha: 0.72),
            gridCornerColor: colors.primary,
            scrimColor: Colors.black54,
            alwaysShowThirdLines: true,
          ),
        ),
      ),
    );
  }
}
