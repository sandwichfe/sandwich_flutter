import 'dart:async';

import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';
import 'emby_pc_toast.dart';

// 设置页入口：从 TMDB 批量刮削演员资料（简介/生日/性别/Tmdb 与 IMDb 编号）与图片。
// 刮削只在服务端手动触发，本页负责提交范围参数并轮询进度。
class EmbyPcPersonScrapePage extends StatefulWidget {
  // embedded 为 true 时只输出内容区，供设置页内嵌显示，不再套一层 Scaffold。
  final bool embedded;

  const EmbyPcPersonScrapePage({super.key, this.embedded = false});

  @override
  State<EmbyPcPersonScrapePage> createState() => _EmbyPcPersonScrapePageState();
}

class _EmbyPcPersonScrapePageState extends State<EmbyPcPersonScrapePage> {
  static const _pollInterval = Duration(milliseconds: 1500);

  // 默认只补缺：已有人工整理或已刮削过的演员不再重复覆盖。
  bool _onlyMissing = true;
  bool _force = false;

  bool _loading = true;
  bool _starting = false;
  bool _canceling = false;
  bool _configured = false;
  String _error = '';

  EmbyPcPersonScrapeJob? _job;
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
      final result = await EmbyPcService.instance.getPersonScrapeJobs();
      if (!mounted) return;
      setState(() {
        _configured = result.configured;
        // 重新进入页面时恢复最近一次任务，进度不会因为离开设置页而丢失。
        _job = result.jobs.isEmpty ? null : result.jobs.first;
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
      final latest = await EmbyPcService.instance.getPersonScrapeJob(job.id);
      if (!mounted) return;
      final finished = !latest.isRunning;
      setState(() {
        _job = latest;
        _pollFailures = 0;
      });
      if (finished) {
        _toast(
          latest.isCanceled ? '已取消演员刮削' : _summary(latest),
          type: latest.isCanceled
              ? EmbyPcToastType.info
              : EmbyPcToastType.success,
        );
      }
      _syncPolling();
    } catch (error) {
      // 服务端重启会丢失任务，连续失败后停止轮询并明确提示。
      _pollFailures++;
      if (_pollFailures >= 3) {
        _pollTimer?.cancel();
        _pollTimer = null;
        _toast('无法获取刮削进度：$error', type: EmbyPcToastType.error);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _start() async {
    if (_jobRunning || _starting) return;

    setState(() => _starting = true);
    try {
      final job = await EmbyPcService.instance.startPersonScrapeJob(
        mode: _onlyMissing ? 'missing' : 'all',
        force: _force,
      );
      if (!mounted) return;
      setState(() {
        _job = job;
        _pollFailures = 0;
      });
      _toast('已开始刮削 ${job.total} 位演员');
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
      final latest = await EmbyPcService.instance.cancelPersonScrapeJob(job.id);
      if (!mounted) return;
      setState(() => _job = latest);
      _toast('已请求取消，当前演员处理完后停止');
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

  static String _summary(EmbyPcPersonScrapeJob job) {
    if (job.completed == 0 && job.skipped > 0) {
      return '没有匹配到可刮削的演员，${job.skipped} 位需要人工确认';
    }
    return '刮削完成：成功 ${job.completed} 位，更新 ${job.updated} 位，图片 ${job.images} 张';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _buildBody();
    return Scaffold(
      appBar: AppBar(title: const Text('演员刮削')),
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
        if (!_configured) ...[_buildConfigHint(), const SizedBox(height: 20)],
        const _ScrapeSectionTitle('刮削设置'),
        _buildSetupCard(),
        const SizedBox(height: 20),
        const _ScrapeSectionTitle('任务进度'),
        _buildProgressCard(),
      ],
    );
  }

  Widget _buildConfigHint() {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.errorContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.error.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_off_outlined, size: 18, color: colors.error),
                const SizedBox(width: 8),
                const Text(
                  '未配置 TMDB API Key',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '在 config.yaml 的 tmdb.api_key 填入 TMDB 免费申请的 Key'
              '（或设置环境变量 EMBYX_TMDB_API_KEY），重启服务后即可使用。'
              '国内网络通常还需要配置 tmdb.proxy。',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupCard() {
    final colors = Theme.of(context).colorScheme;
    final disabled = !_configured || _jobRunning || _starting;

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
            Row(
              children: [
                const Expanded(child: Text('刮削范围')),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<bool>(value: true, label: Text('仅缺资料')),
                    ButtonSegment<bool>(value: false, label: Text('全部演员')),
                  ],
                  selected: {_onlyMissing},
                  onSelectionChanged: disabled
                      ? null
                      : (selection) =>
                            setState(() => _onlyMissing = selection.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _onlyMissing
                  ? '只处理还没有 TMDB 编号或从未刮削过的演员，适合日常增量刷新。'
                  : '重新刮削所有有作品的演员，人数多时耗时较长。',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _force,
              onChanged: disabled
                  ? null
                  : (value) => setState(() => _force = value),
              title: const Text('覆盖已有资料'),
              subtitle: Text(
                _force
                    ? '简介、生日、性别等字段会用 TMDB 数据覆盖；手动编辑过的字段与锁定的图片仍然保留。'
                    : '只填空字段，已有内容一律不动（推荐）。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: disabled ? null : _start,
                    icon: _starting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.person_search_rounded),
                    label: Text(_jobRunning ? '刮削中…' : '开始刮削'),
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
                    job == null
                        ? '暂无任务'
                        : '${job.scopeLabel}${job.force ? '（覆盖）' : ''}',
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
                '点击「开始刮削」后，服务端会按姓名或影片演职员表匹配 TMDB 人物。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              )
            else ...[
              if (job.isRunning && job.currentItem.isNotEmpty) ...[
                _ScrapeProgressLine(label: '正在处理', value: job.currentItem),
                const SizedBox(height: 6),
              ],
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _ScrapeStat(
                    label: job.statusLabel,
                    value: '${job.finishedCount}/${job.total}',
                    highlight: true,
                  ),
                  _ScrapeStat(label: '成功', value: '${job.completed}'),
                  _ScrapeStat(label: '更新', value: '${job.updated}'),
                  _ScrapeStat(label: '图片', value: '${job.images}'),
                  _ScrapeStat(label: '待确认', value: '${job.skipped}'),
                  _ScrapeStat(label: '失败', value: '${job.failed}'),
                ],
              ),
              if (job.skipped > 0 && !job.isRunning) ...[
                const SizedBox(height: 10),
                Text(
                  '「待确认」是同名演员无法唯一确定或 TMDB 没有对应条目，'
                  '这些演员的资料不会被改动，可以稍后重试或手动补全。',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
              if (job.errors.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final error in job.errors)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      error,
                      style: TextStyle(color: colors.error, fontSize: 11),
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

class _ScrapeSectionTitle extends StatelessWidget {
  const _ScrapeSectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: colors.primary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ScrapeProgressLine extends StatelessWidget {
  const _ScrapeProgressLine({required this.label, required this.value});

  final String label;
  final String value;

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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _ScrapeStat extends StatelessWidget {
  const _ScrapeStat({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: highlight ? colors.primary : null,
          ),
        ),
        Text(
          label,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
        ),
      ],
    );
  }
}
