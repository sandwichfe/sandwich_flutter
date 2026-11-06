import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';

// 媒体库管理页直接对接 Emby 的 VirtualFolders 接口：
// 列表只读，所有写操作都由后端校验管理员权限。
class EmbyPcLibraryAdminPage extends StatefulWidget {
  // embedded 为 true 时只输出工具栏 + 列表，供设置页内嵌显示。
  final bool embedded;

  const EmbyPcLibraryAdminPage({super.key, this.embedded = false});

  @override
  State<EmbyPcLibraryAdminPage> createState() => _EmbyPcLibraryAdminPageState();
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
  refreshCover,
  generateArtwork,
  edit,
  delete,
}

class _EmbyPcLibraryAdminPageState extends State<EmbyPcLibraryAdminPage> {
  List<EmbyPcVirtualFolder> _folders = const [];
  // 侧栏排序号由本地保存，列表按它展示，改号即写入偏好。
  List<String> _order = const [];
  bool _loading = true;
  String _error = '';
  bool _creating = false;
  bool _scanningAll = false;
  final Set<String> _busyIds = {};

  // 扫描是后端的异步任务，接口返回时条目还没入库：
  // 触发后轮询 /Library/ScanStatus 读服务端维护的实时计数（S5.3），
  // 扫描结束再刷一次列表拿最新条目数。
  Timer? _scanPollTimer;
  bool _scanPolling = false;
  EmbyPcScanStatus? _scanStatus;
  // 触发扫描后服务端要过一会儿才置 running，连续两次空闲才算真正结束。
  int _scanIdleRounds = 0;
  static const _scanPollInterval = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scanPollTimer?.cancel();
    super.dispose();
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
      final savedOrder =
          (await EmbyPcService.instance.readPreferences()).libraryOrder;
      if (!mounted) return;
      final order = _reconcileOrder(savedOrder, folders);
      // 新建或删除库后补齐排序号，保证侧栏和列表用的是同一份顺序。
      if (order.join(',') != savedOrder.join(',')) {
        unawaited(EmbyPcService.instance.saveLibraryOrder(order));
      }
      setState(() {
        _folders = folders;
        _order = order;
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
  // 返回是否成功，调用方据此决定要不要启动扫描轮询。
  Future<bool> _runForLibrary(
    EmbyPcVirtualFolder folder,
    Future<void> Function() action,
    String successMessage,
  ) async {
    if (_busyIds.contains(folder.id)) return false;
    setState(() => _busyIds.add(folder.id));
    try {
      await action();
      if (!mounted) return true;
      _toast(successMessage);
      await _load(silent: true);
      return true;
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
      return false;
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
      _startScanPolling();
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _editLibrary(EmbyPcVirtualFolder folder) async {
    final draft = await showDialog<_LibraryDraft>(
      context: context,
      // 排序号与封面来源都在编辑弹窗里改，列表行只保留操作入口。
      builder: (_) => _LibraryEditorDialog(
        folder: folder,
        sortOrder: _orderOf(folder.id),
        maxSortOrder: _folders.length,
      ),
    );
    if (draft == null || !mounted) return;

    final saved = await _runForLibrary(
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
    if (!saved || !mounted) return;

    // 排序号有变化时再写偏好，避免无意义的保存。
    final target = draft.sortOrder;
    if (target != null && target != _orderOf(folder.id)) {
      _moveLibraryTo(folder.id, target, notify: false);
    }
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

  Future<void> _scanLibrary(EmbyPcVirtualFolder folder) async {
    final started = await _runForLibrary(folder, () async {
      await EmbyPcService.instance.scanLibraryItem(folder.id);
    }, '已开始扫描「${folder.name}」，列表会自动刷新');
    if (started && mounted) _startScanPolling();
  }

  // 刷新媒体库图片：只重拼库封面（取库内最近条目的海报），不重新扫描条目。
  Future<void> _refreshLibraryCover(EmbyPcVirtualFolder folder) async {
    if (_busyIds.contains(folder.id)) return;
    setState(() => _busyIds.add(folder.id));
    try {
      final updated = await EmbyPcService.instance.refreshLibraryCover(
        folder.id,
      );
      if (!mounted) return;
      _toast(
        updated ? '已刷新「${folder.name}」的封面' : '「${folder.name}」暂无可用海报，封面未更新',
        type: updated ? EmbyPcToastType.success : EmbyPcToastType.info,
      );
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _busyIds.remove(folder.id));
    }
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
      if (!mounted) return;
      _toast('已开始扫描全部媒体库，列表会自动刷新');
      _startScanPolling();
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _scanningAll = false);
    }
  }

  // 先立即拉一次，避免第一帧还显示上一次的状态，然后再按固定间隔轮询。
  void _startScanPolling() {
    if (!mounted) return;
    _scanPollTimer?.cancel();
    _scanIdleRounds = 0;
    setState(() {
      _scanPolling = true;
      // 清掉上一轮的统计，避免新扫描开始时还显示旧进度。
      _scanStatus = null;
    });
    _pollScanProgress();
    _scanPollTimer = Timer.periodic(_scanPollInterval, (_) {
      _pollScanProgress();
    });
  }

  void _stopScanPolling() {
    _scanPollTimer?.cancel();
    _scanPollTimer = null;
    if (!mounted) {
      _scanPolling = false;
      return;
    }
    setState(() => _scanPolling = false);
  }

  Future<void> _pollScanProgress() async {
    try {
      final status = await EmbyPcService.instance.getScanStatus();
      if (!mounted) return;
      setState(() => _scanStatus = status);
      if (status.running) {
        _scanIdleRounds = 0;
        return;
      }

      // 服务端报告扫描结束：连续两次空闲才停，避开刚触发扫描时的空档。
      _scanIdleRounds++;
      if (_scanIdleRounds < 2) return;
      _stopScanPolling();
      await _load(silent: true);
    } catch (_) {
      // 扫描期间偶发请求失败不打断页面，下一轮继续尝试。
    }
  }

  // 已保存的顺序里可能缺新库、也可能残留已删除的库，统一补齐后返回完整顺序。
  List<String> _reconcileOrder(
    List<String> saved,
    List<EmbyPcVirtualFolder> folders,
  ) {
    final ids = folders.map((folder) => folder.id).toSet();
    final order = <String>[
      for (final id in saved)
        if (ids.contains(id)) id,
    ];
    // 新库按接口返回顺序追加到末尾，避免列表跳动。
    for (final folder in folders) {
      if (!order.contains(folder.id)) order.add(folder.id);
    }
    return order;
  }

  // 列表按排序号展示；排序号在 1 起算，直接对应界面上可编辑的数字。
  List<EmbyPcVirtualFolder> get _orderedFolders {
    final position = {for (var i = 0; i < _order.length; i++) _order[i]: i};
    final list = List<EmbyPcVirtualFolder>.of(_folders);
    list.sort(
      (a, b) =>
          (position[a.id] ?? 1 << 30).compareTo(position[b.id] ?? 1 << 30),
    );
    return list;
  }

  int _orderOf(String id) {
    final index = _order.indexOf(id);
    return index < 0 ? _order.length + 1 : index + 1;
  }

  // 直接改排序号：把该库移动到目标位置后立即写入本地偏好。
  void _moveLibraryTo(String id, int target, {bool notify = true}) {
    final order = List<String>.of(_order);
    final from = order.indexOf(id);
    if (from < 0) return;
    final to = (target - 1).clamp(0, order.length - 1);
    if (from == to) {
      if (notify) setState(() {});
      return;
    }
    final moved = order.removeAt(from);
    order.insert(to, moved);
    setState(() => _order = order);
    unawaited(EmbyPcService.instance.saveLibraryOrder(order));
    if (!notify) return;
    _toast(
      '「${_folders.firstWhere((item) => item.id == id).name}」排序号已改为 ${to + 1}',
    );
  }

  List<Widget> _buildToolbarActions() => [
    IconButton(
      tooltip: '刷新列表',
      onPressed: () => _load(),
      icon: const Icon(Icons.refresh),
    ),
    // 扫描是重操作，用带文字的按钮和"刷新列表"的图标区分开。
    TextButton.icon(
      onPressed: (_scanningAll || _scanPolling) ? null : _scanAll,
      icon: _scanningAll || _scanPolling
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.radar_outlined, size: 18),
      label: Text(_scanPolling ? '扫描中' : '扫描全部'),
    ),
    IconButton(
      tooltip: '新建媒体库',
      onPressed: _creating ? null : _createLibrary,
      icon: const Icon(Icons.add),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      final colors = Theme.of(context).colorScheme;
      return Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.outlineVariant)),
            ),
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: _buildToolbarActions(),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体库管理'),
        actions: [..._buildToolbarActions(), const SizedBox(width: 8)],
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

    final folders = _orderedFolders;
    return Column(
      children: [
        if (_scanPolling) _ScanStatusBanner(status: _scanStatus),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: folders.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, index) =>
                _buildTile(context, folders[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildTile(BuildContext context, EmbyPcVirtualFolder folder) {
    final busy = _busyIds.contains(folder.id);
    final locations = folder.locations;
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(_iconFor(folder.collectionType)),
      title: Text(folder.name),
      // 目录与统计信息分两行：目录可能很长，混在一行会把条目数和封面来源挤掉。
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            locations.isEmpty ? '未配置目录' : locations.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${folder.itemCount} 个条目'
            ' · ${folder.preferLocalArtwork ? '海报取目录图' : '海报取生成图'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            PopupMenuButton<_LibraryAdminAction>(
              tooltip: '媒体库操作',
              onSelected: (action) {
                switch (action) {
                  case _LibraryAdminAction.scan:
                    _scanLibrary(folder);
                  case _LibraryAdminAction.refreshCover:
                    _refreshLibraryCover(folder);
                  case _LibraryAdminAction.generateArtwork:
                    _generateLibraryArtwork(folder);
                  case _LibraryAdminAction.edit:
                    _editLibrary(folder);
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
                  value: _LibraryAdminAction.refreshCover,
                  child: ListTile(
                    leading: Icon(Icons.wallpaper_outlined),
                    title: Text('刷新媒体库封面'),
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
                const PopupMenuItem(
                  value: _LibraryAdminAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
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
  // 侧栏排序号，仅编辑时回传；新建的库总是追加到末尾。
  final int? sortOrder;

  const _LibraryDraft({
    required this.name,
    required this.collectionType,
    required this.paths,
    required this.preferLocalArtwork,
    this.sortOrder,
  });
}

// 新建与编辑共用：folder 为空表示新建。
class _LibraryEditorDialog extends StatefulWidget {
  final EmbyPcVirtualFolder? folder;
  // 编辑时传入当前排序号，为空则不显示排序输入框。
  final int? sortOrder;
  final int maxSortOrder;

  const _LibraryEditorDialog({
    this.folder,
    this.sortOrder,
    this.maxSortOrder = 1,
  });

  @override
  State<_LibraryEditorDialog> createState() => _LibraryEditorDialogState();
}

class _LibraryEditorDialogState extends State<_LibraryEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController = TextEditingController(
    text: widget.folder?.name ?? '',
  );
  late final TextEditingController _sortController = TextEditingController(
    text: widget.sortOrder == null ? '' : '${widget.sortOrder}',
  );
  // 输入框只负责新增一条目录，已添加的目录逐项展示在下方列表里。
  final _pathController = TextEditingController();
  late final List<String> _paths = List<String>.of(
    widget.folder?.locations ?? const <String>[],
  );
  late String _collectionType = widget.folder?.collectionType ?? 'movies';
  // 每个库单独决定封面来源，默认与升级前一致：读取目录内的海报/封面。
  late bool _preferLocalArtwork = widget.folder?.preferLocalArtwork ?? true;

  @override
  void dispose() {
    _nameController.dispose();
    _sortController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  // 排序号只认 1..库数量，越界或非数字直接判为非法。
  int get _maxSortOrder => widget.maxSortOrder < 1 ? 1 : widget.maxSortOrder;

  int get _sortOrderValue {
    final parsed = int.tryParse(_sortController.text.trim());
    return (parsed ?? widget.sortOrder ?? 1).clamp(1, _maxSortOrder);
  }

  // 回车、"添加"和目录选择器都走这里，重复路径直接忽略。
  void _addPath(String value) {
    final path = value.trim();
    if (path.isEmpty) return;
    if (_paths.contains(path)) {
      _pathController.clear();
      return;
    }
    setState(() {
      _paths.add(path);
      _pathController.clear();
    });
    // 加入目录后重新校验，让"至少需要一个目录"的报错及时消失。
    _formKey.currentState?.validate();
  }

  void _removePath(String path) {
    setState(() => _paths.remove(path));
    _formKey.currentState?.validate();
  }

  Future<void> _pickDirectory() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择媒体目录',
      );
      if (path == null || !mounted) return;
      _addPath(path);
    } catch (error) {
      if (mounted) {
        EmbyPcToast.show(context, '选择目录失败：$error', type: EmbyPcToastType.error);
      }
    }
  }

  // 一个目录一行，长路径省略显示，悬停可看到完整路径，右侧单独移除。
  Widget _buildPathRow(BuildContext context, String path) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: path,
              waitDuration: const Duration(milliseconds: 500),
              child: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          IconButton(
            tooltip: '移除',
            visualDensity: VisualDensity.compact,
            onPressed: () => _removePath(path),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      _LibraryDraft(
        name: _nameController.text.trim(),
        collectionType: _collectionType,
        paths: List<String>.of(_paths),
        preferLocalArtwork: _preferLocalArtwork,
        sortOrder: widget.folder == null ? null : _sortOrderValue,
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
                // 名称与排序号并排：排序号只在编辑时出现，改完保存即同步侧栏。
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _nameController,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: '名称',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? '请输入媒体库名称'
                            : null,
                      ),
                    ),
                    if (isEditing) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 112,
                        child: TextFormField(
                          controller: _sortController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '排序号',
                            helperText: '同步到侧栏',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final parsed = int.tryParse((value ?? '').trim());
                            if (parsed == null) return '请输入数字';
                            if (parsed < 1 || parsed > _maxSortOrder) {
                              return '范围 1-$_maxSortOrder';
                            }
                            return null;
                          },
                        ),
                      ),
                    ],
                  ],
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
                // 目录逐条添加：输入框只填一条，回车或"添加"后进入下方列表。
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _pathController,
                        decoration: InputDecoration(
                          labelText: '目录',
                          hintText: '服务器可访问的绝对路径',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: '选择目录',
                            onPressed: _pickDirectory,
                            icon: const Icon(Icons.folder_open),
                          ),
                        ),
                        onFieldSubmitted: _addPath,
                        // 目录列表不在表单值里，校验直接看当前条目数。
                        validator: (_) => _paths.isEmpty ? '至少需要一个目录' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => _addPath(_pathController.text),
                      child: const Text('添加'),
                    ),
                  ],
                ),
                if (_paths.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 168),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final path in _paths)
                              _buildPathRow(context, path),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
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
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
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
        EmbyPcToast.show(
          context,
          error.toString(),
          type: EmbyPcToastType.error,
        );
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

// 扫描进度横幅：数据来自 /Library/ScanStatus，包含当前文件与失败数量。
class _ScanStatusBanner extends StatelessWidget {
  final EmbyPcScanStatus? status;

  const _ScanStatusBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final value = status;
    final scanned = value?.scanned ?? 0;
    final total = value?.total ?? 0;
    final libraryName = value?.libraryName ?? '';
    final title = total > 0
        ? '正在扫描${libraryName.isEmpty ? '' : '「$libraryName」'}：$scanned / $total'
        : '正在扫描：已处理 $scanned 个文件';

    return Material(
      color: colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: textTheme.bodyMedium),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: value?.ratio),
            if (value != null && value.currentPath.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                value.currentPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall,
              ),
            ],
            if (value != null && value.failures.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '失败 ${value.failures.length} 个（详见服务端日志）',
                style: textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

