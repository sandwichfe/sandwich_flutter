import 'dart:async';

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

enum _LibraryAdminAction {
  scan,
  generateArtwork,
  edit,
  toggleArtworkSource,
  delete,
}

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
        preferLocalArtwork: draft.preferLocalArtwork,
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
        preferLocalArtwork: draft.preferLocalArtwork,
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

  // 封面来源按库切换：只改渲染取图，不重扫媒体库。
  Future<void> _toggleArtworkSource(EmbyPcVirtualFolder folder) {
    final preferLocal = !folder.preferLocalArtwork;
    return _runForLibrary(
      folder,
      () => EmbyPcService.instance.setLibraryPreferLocalArtwork(
        folder.id,
        preferLocal,
      ),
      preferLocal ? '「${folder.name}」改用目录内的海报' : '「${folder.name}」改用生成的封面',
    );
  }

  // 整库批量生成：后端只处理缺图的条目，任务在后台跑，弹窗轮询进度。
  Future<void> _generateLibraryArtwork(EmbyPcVirtualFolder folder) async {
    final options = await showDialog<_GenerateArtworkOptions>(
      context: context,
      builder: (_) => _GenerateArtworkConfirmDialog(folder: folder),
    );
    if (options == null || !mounted) return;

    final EmbyPcArtworkJob job;
    try {
      job = await EmbyPcService.instance.startArtworkJob(
        folder.id,
        force: options.force,
        positionRatio: options.positionRatio,
      );
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
      return;
    }
    if (!mounted) return;

    final result = await showDialog<EmbyPcArtworkJob>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ArtworkJobDialog(job: job),
    );
    if (!mounted) return;
    // 关掉弹窗时任务还在跑，交给后台继续，不打断用户。
    if (result == null || result.isRunning) return;

    await _load(silent: true);
    if (!mounted) return;
    if (result.isCanceled) {
      _toast('已取消「${folder.name}」的生成任务');
      return;
    }
    _toast(
      result.failed == 0
          ? '「${folder.name}」已生成 ${result.generated} 张图片'
          : '「${folder.name}」生成完成：成功 ${result.completed}，失败 ${result.failed}',
    );
  }

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
        '${locations.isEmpty ? '未配置目录' : locations.join(' · ')}'
        ' · ${folder.itemCount} 个条目'
        ' · ${folder.preferLocalArtwork ? '海报取目录图' : '海报取生成图'}',
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
                  case _LibraryAdminAction.generateArtwork:
                    _generateLibraryArtwork(folder);
                  case _LibraryAdminAction.edit:
                    _editLibrary(folder);
                  case _LibraryAdminAction.toggleArtworkSource:
                    _toggleArtworkSource(folder);
                  case _LibraryAdminAction.delete:
                    _deleteLibrary(folder);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _LibraryAdminAction.scan,
                  child: ListTile(
                    leading: Icon(Icons.refresh),
                    title: Text('扫描媒体库'),
                  ),
                ),
                const PopupMenuItem(
                  value: _LibraryAdminAction.generateArtwork,
                  child: ListTile(
                    leading: Icon(Icons.auto_awesome_outlined),
                    title: Text('生成海报和封面'),
                  ),
                ),
                const PopupMenuItem(
                  value: _LibraryAdminAction.edit,
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('编辑'),
                  ),
                ),
                PopupMenuItem(
                  value: _LibraryAdminAction.toggleArtworkSource,
                  child: ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text(
                      folder.preferLocalArtwork ? '改用生成的封面' : '改用目录内的海报',
                    ),
                  ),
                ),
                const PopupMenuItem(
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
  final bool preferLocalArtwork;

  const _LibraryDraft({
    required this.name,
    required this.collectionType,
    required this.paths,
    required this.preferLocalArtwork,
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
  // 每个库单独决定封面来源，默认与升级前一致：读取目录内的海报/封面。
  late bool _preferLocalArtwork = widget.folder?.preferLocalArtwork ?? true;

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
        preferLocalArtwork: _preferLocalArtwork,
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
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.image_outlined),
                  title: const Text('读取目录内的海报和封面'),
                  subtitle: const Text(
                    '关闭后使用服务端从视频画面生成的图片；目录内没有海报或封面时同样回退到生成图',
                  ),
                  value: _preferLocalArtwork,
                  onChanged: (value) =>
                      setState(() => _preferLocalArtwork = value),
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

// 批量生成前的确认：说明只处理缺图条目，可选是否全部重来。
// 批量生成的取帧方式与覆盖策略，作为确认弹窗的返回值。
class _GenerateArtworkOptions {
  final bool force;
  // 0 表示自动嗅探；否则是按片长比例指定的进度点（0.02~0.98）。
  final double positionRatio;

  const _GenerateArtworkOptions({
    required this.force,
    required this.positionRatio,
  });
}

// 批量生成前的确认：可选自动嗅探或指定进度点，以及是否全部重来。
// 返回 null 表示取消。
class _GenerateArtworkConfirmDialog extends StatefulWidget {
  final EmbyPcVirtualFolder folder;

  const _GenerateArtworkConfirmDialog({required this.folder});

  @override
  State<_GenerateArtworkConfirmDialog> createState() =>
      _GenerateArtworkConfirmDialogState();
}

class _GenerateArtworkConfirmDialogState
    extends State<_GenerateArtworkConfirmDialog> {
  bool _sniff = true;
  // 与前端的单条目生成保持一致，默认取 30% 处。
  double _percent = 0.30;
  bool _force = false;

  String get _positionLabel => '${(_percent * 100).round()}%';

  void _confirm() {
    Navigator.pop(
      context,
      _GenerateArtworkOptions(
        force: _force,
        positionRatio: _sniff ? 0 : _percent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('生成海报和封面 · ${widget.folder.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '从每个视频的画面里取一帧，生成竖版海报和横版封面。'
                '默认只处理还没有图片的条目，条目较多时会在后台逐条执行。',
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动嗅探画面'),
                subtitle: const Text('在片长中段抽样若干帧，自动选择画面最清晰的一帧'),
                value: _sniff,
                onChanged: (value) => setState(() => _sniff = value),
              ),
              if (!_sniff) ...[
                Text('取帧进度：$_positionLabel（每条视频按自己的片长换算）'),
                Slider(
                  value: _percent,
                  min: 0.02,
                  max: 0.98,
                  divisions: 96,
                  label: _positionLabel,
                  onChanged: (value) => setState(() => _percent = value),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('全部重新生成'),
                subtitle: const Text('覆盖已存在的生成图，耗时明显更长'),
                value: _force,
                onChanged: (value) => setState(() => _force = value),
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
        FilledButton(onPressed: _confirm, child: const Text('开始生成')),
      ],
    );
  }
}

// 轮询任务进度；关闭弹窗任务会继续在后台跑。
class _ArtworkJobDialog extends StatefulWidget {
  final EmbyPcArtworkJob job;

  const _ArtworkJobDialog({required this.job});

  @override
  State<_ArtworkJobDialog> createState() => _ArtworkJobDialogState();
}

class _ArtworkJobDialogState extends State<_ArtworkJobDialog> {
  late EmbyPcArtworkJob _job = widget.job;
  Timer? _timer;
  bool _canceling = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    if (!_job.isRunning) return;
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _poll(),
    );
  }

  Future<void> _poll() async {
    try {
      final job = await EmbyPcService.instance.getArtworkJob(_job.id);
      if (!mounted) return;
      setState(() => _job = job);
      if (!job.isRunning) {
        _timer?.cancel();
        _timer = null;
      }
    } catch (_) {
      // 单次轮询失败不影响任务本身，下一次继续。
    }
  }

  Future<void> _cancel() async {
    if (_canceling) return;
    setState(() => _canceling = true);
    try {
      final job = await EmbyPcService.instance.cancelArtworkJob(_job.id);
      if (mounted) setState(() => _job = job);
    } catch (error) {
      if (mounted) {
        EmbyPcToast.show(context, error.toString(), type: EmbyPcToastType.error);
      }
    } finally {
      if (mounted) setState(() => _canceling = false);
    }
  }

  String get _statusText {
    if (_job.isRunning) {
      return '已处理 ${_job.processed} / ${_job.total}，已生成 ${_job.generated} 张';
    }
    if (_job.isCanceled) {
      return '已取消：成功 ${_job.completed}，失败 ${_job.failed}，已生成 ${_job.generated} 张';
    }
    return '已完成：成功 ${_job.completed}，失败 ${_job.failed}，已生成 ${_job.generated} 张';
  }

  @override
  Widget build(BuildContext context) {
    final errors = _job.errors;
    return AlertDialog(
      title: Text('生成海报和封面 · ${_job.libraryName}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _job.progress),
            const SizedBox(height: 12),
            Text(_statusText),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _job.positionRatio > 0
                    ? '取帧方式：固定进度 ${(_job.positionRatio * 100).round()}%（按各自片长换算）'
                    : '取帧方式：自动嗅探画面',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_job.isRunning && _job.currentItem.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '正在处理：${_job.currentItem}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  errors.first,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (_job.isRunning)
          TextButton(
            onPressed: _canceling ? null : _cancel,
            child: const Text('取消任务'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _job),
          child: Text(_job.isRunning ? '后台运行' : '关闭'),
        ),
      ],
    );
  }
}
