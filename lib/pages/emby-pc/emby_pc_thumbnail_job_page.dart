import 'dart:async';

import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';

// 设置页入口：按媒体库批量预生成进度条缩略图（BIF）。
// 抽帧在服务端后台执行，本页只负责提交参数并按固定间隔轮询进度。
class EmbyPcThumbnailJobPage extends StatefulWidget {
  const EmbyPcThumbnailJobPage({super.key});

  @override
  State<EmbyPcThumbnailJobPage> createState() => _EmbyPcThumbnailJobPageState();
}

class _EmbyPcThumbnailJobPageState extends State<EmbyPcThumbnailJobPage> {
  static const _widthOptions = <int>[240, 320, 480];
  static const _pollInterval = Duration(milliseconds: 1500);

  List<EmbyPcVirtualFolder> _folders = const [];
  String _selectedLibraryId = '';
  double _intervalSeconds = 10;
  int _width = 320;

  bool _loading = true;
  bool _starting = false;
  bool _canceling = false;
  String _error = '';

  EmbyPcThumbnailJob? _job;
  Timer? _pollTimer;
  int _pollFailures = 0;
  bool _polling = false;

  bool get _jobRunning => _job?.isRunning ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final folders = await EmbyPcService.instance.getVirtualFolders();
      final jobs = await EmbyPcService.instance.getThumbnailJobs();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _selectedLibraryId = _pickLibraryId(folders);
        // 重新进入页面时恢复最近一次任务，进度不会因为离开设置页而丢失。
        _job = jobs.isEmpty ? null : jobs.first;
        _loading = false;
      });
      _syncPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  // 优先选中已有条目的库，避免默认落到空库后直接报错。
  String _pickLibraryId(List<EmbyPcVirtualFolder> folders) {
    if (folders.isEmpty) return '';
    if (folders.any((folder) => folder.id == _selectedLibraryId)) {
      return _selectedLibraryId;
    }
    for (final folder in folders) {
      if (folder.itemCount > 0) return folder.id;
    }
    return folders.first.id;
  }

  // 只有运行中的任务才需要轮询，任务结束后立即停表。
  void _syncPolling() {
    if (_jobRunning) {
      _pollTimer ??= Timer.periodic(_pollInterval, (_) => _pollJob());
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollJob() async {
    final job = _job;
    if (job == null || !job.isRunning) {
      _syncPolling();
      return;
    }
    // 上一轮请求还没回来时跳过本次，避免慢网络下请求堆积。
    if (_polling) return;
    _polling = true;
    try {
      final latest = await EmbyPcService.instance.getThumbnailJob(job.id);
      if (!mounted) return;
      final finished = !latest.isRunning;
      setState(() {
        _job = latest;
        _pollFailures = 0;
      });
      if (finished) {
        _toast(
          latest.isCanceled
              ? '已取消「${latest.libraryName}」缩略图生成'
              : '「${latest.libraryName}」缩略图生成完成',
          type: latest.isCanceled
              ? EmbyPcToastType.info
              : EmbyPcToastType.success,
        );
      }
      _syncPolling();
    } catch (error) {
      // 服务端重启会丢失任务，连续失败后停止轮询并明确提示，不再静默停摆。
      _pollFailures++;
      if (_pollFailures >= 3) {
        _pollTimer?.cancel();
        _pollTimer = null;
        _toast('无法获取生成进度：$error', type: EmbyPcToastType.error);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _start() async {
    if (_selectedLibraryId.isEmpty) {
      _toast('请先选择媒体库', type: EmbyPcToastType.error);
      return;
    }
    if (_jobRunning || _starting) return;

    setState(() => _starting = true);
    try {
      final job = await EmbyPcService.instance.startThumbnailJob(
        libraryId: _selectedLibraryId,
        intervalSeconds: _intervalSeconds.round(),
        width: _width,
      );
      if (!mounted) return;
      setState(() {
        _job = job;
        _pollFailures = 0;
      });
      _toast('已开始生成「${job.libraryName}」缩略图');
      _syncPolling();
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _cancel() async {
    final job = _job;
    if (job == null || !job.isRunning || _canceling) return;

    setState(() => _canceling = true);
    try {
      final latest = await EmbyPcService.instance.cancelThumbnailJob(job.id);
      if (!mounted) return;
      setState(() => _job = latest);
      _toast('已请求取消，当前条目完成后停止');
      _syncPolling();
    } catch (error) {
      if (mounted) _toast(error.toString(), type: EmbyPcToastType.error);
    } finally {
      if (mounted) setState(() => _canceling = false);
    }
  }

  void _toast(
    String message, {
    EmbyPcToastType type = EmbyPcToastType.success,
  }) {
    if (!mounted) return;
    EmbyPcToast.show(context, message, type: type);
  }

  // 时长按中文习惯分级展示，避免出现 "7320 秒" 这类难读的数字。
  static String _formatDuration(int seconds) {
    if (seconds <= 0) return '0 分';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return minutes > 0 ? '$hours 小时 $minutes 分' : '$hours 小时';
    }
    if (minutes > 0) return '$minutes 分';
    return '$seconds 秒';
  }

  // 条目缺少时长信息时总时长为 0，这里直接说明，避免显示 0 分产生误解。
  static String _durationRange(int done, int total) {
    if (total <= 0) return '未知（条目缺少时长信息）';
    return '${_formatDuration(done)} / 共 ${_formatDuration(total)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('进度条缩略图')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        const _ThumbnailSectionTitle('生成设置'),
        _buildSetupCard(),
        const SizedBox(height: 20),
        const _ThumbnailSectionTitle('任务进度'),
        _buildProgressCard(),
      ],
    );
  }

  Widget _buildSetupCard() {
    final colors = Theme.of(context).colorScheme;
    final disabled = _jobRunning || _starting;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedLibraryId.isEmpty
                  ? null
                  : _selectedLibraryId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '媒体库',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final folder in _folders)
                  DropdownMenuItem<String>(
                    value: folder.id,
                    child: Text(
                      '${folder.name}（${folder.itemCount} 个条目）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: disabled
                  ? null
                  : (value) => setState(() => _selectedLibraryId = value ?? ''),
            ),
            if (_folders.isEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '还没有媒体库，请先在「媒体库管理」中添加并扫描。',
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(child: Text('抽帧间隔')),
                Text(
                  '${_intervalSeconds.round()} 秒/张',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Slider(
              value: _intervalSeconds,
              min: 2,
              max: 60,
              divisions: 29,
              label: '${_intervalSeconds.round()} 秒',
              onChanged: disabled
                  ? null
                  : (value) => setState(() => _intervalSeconds = value),
            ),
            Text(
              '间隔越小拖动预览越细腻，但生成更慢、占用空间更大。',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(child: Text('缩略图宽度')),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (final width in _widthOptions)
                      ButtonSegment<int>(value: width, label: Text('$width')),
                  ],
                  selected: {_width},
                  onSelectionChanged: disabled
                      ? null
                      : (selection) => setState(() => _width = selection.first),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: disabled || _folders.isEmpty ? null : _start,
                    icon: _starting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                    label: Text(_jobRunning ? '生成中…' : '开始生成'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _jobRunning && !_canceling ? _cancel : null,
                  child: Text(_canceling ? '取消中…' : '取消任务'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    final colors = Theme.of(context).colorScheme;
    final job = _job;
    final percent = ((job?.ratio ?? 0) * 100).round();

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    job == null ? '暂无任务' : job.libraryName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (job != null)
                  Text(
                    '$percent%',
                    style: TextStyle(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: job == null ? 0 : job.ratio,
                minHeight: 6,
                backgroundColor: colors.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 12),
            if (job == null)
              Text(
                '选择媒体库与抽帧间隔后点击「开始生成」。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              )
            else ...[
              // 时长是主口径，帧数是辅助口径，二者都由服务端在条目完成时累加。
              _ProgressLine(
                label: '已完成时长',
                value: _durationRange(
                  job.doneDurationSeconds,
                  job.totalDurationSeconds,
                ),
                highlight: true,
              ),
              const SizedBox(height: 6),
              _ProgressLine(
                label: '已生成帧数',
                value: job.estimatedFrames > 0
                    ? '${job.generatedFrames} / 约 ${job.estimatedFrames} 张'
                    : '${job.generatedFrames} 张',
              ),
              if (job.isRunning && job.currentItem.isNotEmpty) ...[
                const SizedBox(height: 6),
                _ProgressLine(
                  label: '正在处理',
                  value: job.currentItemDurationSeconds > 0
                      ? '${job.currentItem}（${_formatDuration(job.currentItemDurationSeconds)}）'
                      : job.currentItem,
                ),
                const SizedBox(height: 6),
                // 条目内进度来自 ffmpeg -progress，能看出大文件解码是否在推进。
                Row(
                  children: [
                    const SizedBox(width: 76),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: job.currentItemProgress,
                          minHeight: 3,
                          backgroundColor: colors.surfaceContainerHighest,
                          color: colors.primary.withValues(alpha: 0.65),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${(job.currentItemProgress * 100).round()}%',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                if (job.currentItemProgress <= 0) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: 76),
                    child: Text(
                      '正在启动抽帧，长片或网络盘上首个条目可能需要数分钟。',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _ProgressStat(
                    label: job.statusLabel,
                    value: '${job.finishedCount}/${job.total}',
                    highlight: true,
                  ),
                  _ProgressStat(label: '成功', value: '${job.completed}'),
                  _ProgressStat(label: '失败', value: '${job.failed}'),
                  _ProgressStat(label: '跳过', value: '${job.skipped}'),
                  _ProgressStat(
                    label: '间隔',
                    value: '${(job.intervalMs / 1000).round()} 秒',
                  ),
                ],
              ),
              if (job.errors.isNotEmpty) ...[
                const SizedBox(height: 8),
                Theme(
                  // ExpansionTile 默认带分隔线，卡片内改用更轻的样式。
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 4),
                    title: Text(
                      '错误明细（${job.errors.length}）',
                      style: TextStyle(color: colors.error, fontSize: 13),
                    ),
                    children: [
                      for (final message in job.errors)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              message,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ThumbnailSectionTitle extends StatelessWidget {
  final String title;

  const _ThumbnailSectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ProgressStat extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _ProgressStat({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
        ),
        Text(
          value,
          style: TextStyle(
            color: highlight ? colors.primary : colors.onSurface,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// 进度卡片里的键值行：标签定宽对齐，值过长时换行截断。
class _ProgressLine extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _ProgressLine({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: highlight ? colors.primary : colors.onSurface,
              fontSize: highlight ? 13 : 12,
              fontWeight: highlight ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
