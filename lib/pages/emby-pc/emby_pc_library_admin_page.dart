import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';

// 媒体库管理页直接对接 Emby 的 VirtualFolders 接口：
// 列表只读，所有写操作都由后端校验管理员权限。
class EmbyPcLibraryAdminPage extends StatefulWidget {
  const EmbyPcLibraryAdminPage({super.key});

  @override
  State<EmbyPcLibraryAdminPage> createState() =>
      _EmbyPcLibraryAdminPageState();
}

// collectionType 与后端 CollectionType 字段一致，界面只做中文展示。
const _collectionTypeLabels = <String, String>{
  'movies': '电影',
  'tvshows': '电视剧',
  'music': '音乐',
  'homevideos': '家庭视频',
  'mixedcontent': '混合内容',
};

enum _LibraryAdminAction { scan, edit, delete }

class _EmbyPcLibraryAdminPageState extends State<EmbyPcLibraryAdminPage> {
  List<EmbyPcVirtualFolder> _folders = const [];
  bool _loading = true;
  String _error = '';
  bool _creating = false;
  bool _scanningAll = false;
  final Set<String> _busyIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  // silent 用于写操作后的静默刷新，避免整页闪回加载态。
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      final folders = await EmbyPcService.instance.getVirtualFolders();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _loading = false;
        _error = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _toast(
    String message, {
    EmbyPcToastType type = EmbyPcToastType.success,
  }) {
    EmbyPcToast.show(context, message, type: type);
  }

  // 单个库的写操作统一走这里，复用忙碌标记与错误提示。
  Future<void> _runForLibrary(
    EmbyPcVirtualFolder folder,
    Future<void> Function() action,
    String successMessage,
  ) async {
    if (_busyIds.contains(folder.id)) return;
    setState(() => _busyIds.add(folder.id));
    try {
      await action();
      if (!mounted) return;
      _toast(successMessage);
      await _load(silent: true);
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _busyIds.remove(folder.id));
    }
  }

  Future<void> _createLibrary() async {
    if (_creating) return;
    final draft = await showDialog<_LibraryDraft>(
      context: context,
      builder: (_) => const _LibraryEditorDialog(),
    );
    if (draft == null || !mounted) return;

    setState(() => _creating = true);
    try {
      await EmbyPcService.instance.createVirtualFolder(
        name: draft.name,
        collectionType: draft.collectionType,
        paths: draft.paths,
      );
      if (!mounted) return;
      _toast('已创建「${draft.name}」，正在后台扫描');
      await _load(silent: true);
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _editLibrary(EmbyPcVirtualFolder folder) async {
    final draft = await showDialog<_LibraryDraft>(
      context: context,
      builder: (_) => _LibraryEditorDialog(folder: folder),
    );
    if (draft == null || !mounted) return;

    await _runForLibrary(
      folder,
      () => EmbyPcService.instance.updateVirtualFolder(
        folder.id,
        name: draft.name,
        collectionType: draft.collectionType,
        paths: draft.paths,
      ),
      '已保存「${draft.name}」',
    );
  }

  Future<void> _deleteLibrary(EmbyPcVirtualFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除媒体库「${folder.name}」？'),
        content: Text(
          folder.itemCount > 0
              ? '将同时清理库内 ${folder.itemCount} 个条目及其缓存图片，删除后无法撤销。'
              : '删除后无法撤销。',
        ),
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

    await _runForLibrary(
      folder,
      () => EmbyPcService.instance.deleteVirtualFolder(folder.id),
      '已删除「${folder.name}」',
    );
  }

  Future<void> _scanLibrary(EmbyPcVirtualFolder folder) => _runForLibrary(
    folder,
    () async {
      await EmbyPcService.instance.scanLibraryItem(folder.id);
    },
    '已开始扫描「${folder.name}」',
  );

  Future<void> _scanAll() async {
    if (_scanningAll) return;
    setState(() => _scanningAll = true);
    try {
      await EmbyPcService.instance.scanLibrary();
      if (mounted) _toast('已开始扫描全部媒体库');
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _scanningAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体库管理'),
        actions: [
          IconButton(
            tooltip: '扫描全部媒体库',
            onPressed: _scanningAll ? null : _scanAll,
            icon: _scanningAll
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '新建媒体库',
            onPressed: _creating ? null : _createLibrary,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 52),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text('还没有媒体库'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _creating ? null : _createLibrary,
              icon: const Icon(Icons.add),
              label: const Text('新建媒体库'),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _folders.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) => _buildTile(_folders[index]),
    );
  }

  Widget _buildTile(EmbyPcVirtualFolder folder) {
    final busy = _busyIds.contains(folder.id);
    final locations = folder.locations;
    return ListTile(
      leading: Icon(_iconFor(folder.collectionType)),
      title: Text(folder.name),
      subtitle: Text(
        locations.isEmpty
            ? '未配置目录 · ${folder.itemCount} 个条目'
            : '${locations.join(' · ')} · ${folder.itemCount} 个条目',
        // 目录可能很长，固定两行避免撑破 ListTile 高度。
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<_LibraryAdminAction>(
              tooltip: '媒体库操作',
              onSelected: (action) {
                switch (action) {
                  case _LibraryAdminAction.scan:
                    _scanLibrary(folder);
                  case _LibraryAdminAction.edit:
                    _editLibrary(folder);
                  case _LibraryAdminAction.delete:
                    _deleteLibrary(folder);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _LibraryAdminAction.scan,
                  child: ListTile(
                    leading: Icon(Icons.refresh),
                    title: Text('扫描媒体库'),
                  ),
                ),
                PopupMenuItem(
                  value: _LibraryAdminAction.edit,
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('编辑'),
                  ),
                ),
                PopupMenuItem(
                  value: _LibraryAdminAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
    );
  }

  IconData _iconFor(String collectionType) => switch (collectionType) {
    'tvshows' => Icons.live_tv_outlined,
    'music' => Icons.library_music_outlined,
    'homevideos' => Icons.videocam_outlined,
    'mixedcontent' => Icons.folder_copy_outlined,
    _ => Icons.movie_outlined,
  };
}

class _LibraryDraft {
  final String name;
  final String collectionType;
  final List<String> paths;

  const _LibraryDraft({
    required this.name,
    required this.collectionType,
    required this.paths,
  });
}

// 新建与编辑共用：folder 为空表示新建。
class _LibraryEditorDialog extends StatefulWidget {
  final EmbyPcVirtualFolder? folder;

  const _LibraryEditorDialog({this.folder});

  @override
  State<_LibraryEditorDialog> createState() => _LibraryEditorDialogState();
}

class _LibraryEditorDialogState extends State<_LibraryEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController = TextEditingController(
    text: widget.folder?.name ?? '',
  );
  late final TextEditingController _pathsController = TextEditingController(
    text: widget.folder?.locations.join('\n') ?? '',
  );
  late String _collectionType = widget.folder?.collectionType ?? 'movies';

  @override
  void dispose() {
    _nameController.dispose();
    _pathsController.dispose();
    super.dispose();
  }

  // 目录以换行分隔，既方便手工粘贴多个路径，也便于目录选择器追加。
  List<String> get _paths => _pathsController.text
      .split('\n')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  Future<void> _pickDirectory() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择媒体目录',
      );
      if (path == null || path.trim().isEmpty || !mounted) return;
      final current = _paths;
      if (current.contains(path)) return;
      current.add(path);
      setState(() => _pathsController.text = current.join('\n'));
    } catch (error) {
      if (mounted) {
        EmbyPcToast.show(
          context,
          '选择目录失败：$error',
          type: EmbyPcToastType.error,
        );
      }
    }
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      _LibraryDraft(
        name: _nameController.text.trim(),
        collectionType: _collectionType,
        paths: _paths,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.folder != null;
    return AlertDialog(
      title: Text(isEditing ? '编辑媒体库' : '新建媒体库'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请输入媒体库名称' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _collectionType,
                  decoration: const InputDecoration(
                    labelText: '类型',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final entry in _collectionTypeLabels.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _collectionType = value);
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _pathsController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: '目录',
                    hintText: '每行一个服务器可访问的绝对路径',
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                    suffixIcon: IconButton(
                      tooltip: '选择目录',
                      onPressed: _pickDirectory,
                      icon: const Icon(Icons.folder_open),
                    ),
                  ),
                  // 目录不在表单值里，校验直接读当前解析结果。
                  validator: (_) => _paths.isEmpty ? '至少需要一个目录' : null,
                ),
              ],
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
          onPressed: _submit,
          child: Text(isEditing ? '保存' : '创建并扫描'),
        ),
      ],
    );
  }
}
