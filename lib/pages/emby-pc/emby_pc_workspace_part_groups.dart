part of 'emby_pc_page.dart';

// 分片影片：按组列出服务端自动识别出的分片归属，供核对"哪些影片被切成了多个文件、
// 有没有把不该合并的串成一组"。只读，不提供解散/合并等维护操作。
class EmbyPcPartGroupsView extends StatefulWidget {
  // 打开组内某个分片的详情页，复用工作台的详情导航。
  final ValueChanged<EmbyPcItem> onOpenItem;

  const EmbyPcPartGroupsView({super.key, required this.onOpenItem});

  @override
  State<EmbyPcPartGroupsView> createState() => _EmbyPcPartGroupsViewState();
}

class _EmbyPcPartGroupsViewState extends State<EmbyPcPartGroupsView> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  bool _onlyMultiple = true;
  bool _loading = true;
  String _error = '';
  List<EmbyPcPartGroup> _groups = const [];
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final page = await EmbyPcService.instance.getPartGroups(
        searchTerm: _searchController.text,
        onlyMultiple: _onlyMultiple,
      );
      if (!mounted) return;
      setState(() {
        _groups = page.groups;
        _total = page.total;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  // 输入变化后稍等再查，避免每敲一个字都发一次请求。
  void _scheduleSearch(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 320), _load);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 14, 26, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '核对同一部影片被切成多个文件后的自动分组结果；点分片可进入详情页确认。',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _buildFilterBar(context),
          const SizedBox(height: 14),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 14,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 300,
          height: 40,
          child: TextField(
            controller: _searchController,
            onChanged: _scheduleSearch,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: colors.surface.withValues(alpha: 0.82),
              hintText: '搜索分片标题或路径',
              prefixIcon: const Icon(Icons.search, size: 19),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(6),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.primary, width: 1.4),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
        // 单段组通常是"删过一段"的残留，默认藏起来，排查时才显示。
        FilterChip(
          label: const Text('只看多段'),
          selected: _onlyMultiple,
          onSelected: (value) {
            setState(() => _onlyMultiple = value);
            _load();
          },
        ),
        OutlinedButton.icon(
          onPressed: _loading ? null : _load,
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.onSurfaceVariant,
            side: BorderSide(color: colors.outlineVariant),
          ),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('刷新'),
        ),
        Text(
          _loading ? '加载中…' : '共 $_total 组',
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 42),
            const SizedBox(height: 12),
            Text(_error, textAlign: TextAlign.center),
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
    if (_loading && _groups.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.call_split_rounded,
              size: 44,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              _searchController.text.trim().isEmpty && _onlyMultiple
                  ? '还没有识别到分片影片'
                  : '没有符合条件的分片组',
            ),
            const SizedBox(height: 6),
            Text(
              '同一部影片被切成 `_1` / `_2` 多个文件并扫描后，这里会出现分组。',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _groups.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder:
          (context, index) => _PartGroupCard(
            group: _groups[index],
            onOpenItem: widget.onOpenItem,
          ),
    );
  }
}

// 一组一张卡片：标题 + 库/段数，下面是成员行，点任意成员进入详情页。
class _PartGroupCard extends StatelessWidget {
  final EmbyPcPartGroup group;
  final ValueChanged<EmbyPcItem> onOpenItem;

  const _PartGroupCard({required this.group, required this.onOpenItem});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final meta = [
      if (group.libraryName.isNotEmpty) group.libraryName,
      '${group.partCount} 段',
    ].join(' · ');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    group.name.isEmpty ? '未命名分组' : group.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Microsoft YaHei UI',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  meta,
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 2),
            // 分组键用于排查：两个库/目录的同名文件不会串组，靠的就是它。
            Tooltip(
              message: group.groupKey,
              child: Text(
                group.groupKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.72),
                  fontSize: 11,
                  fontFamily: 'Consolas',
                ),
              ),
            ),
            const Divider(height: 16),
            ...group.parts.map(
              (part) => _PartMemberRow(
                part: part,
                onOpen: () => onOpenItem(_partToItem(part)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 成员行：段号 + 名称 + 路径 + 时长，双击路径可复制。
class _PartMemberRow extends StatelessWidget {
  final EmbyPcPartMember part;
  final VoidCallback onOpen;

  const _PartMemberRow({required this.part, required this.onOpen});

  Future<void> _copyPath(BuildContext context) async {
    if (part.path.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: part.path));
    if (!context.mounted) return;
    EmbyPcToast.show(
      context,
      '已复制影片路径',
      type: EmbyPcToastType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = _partDurationLabel(part.runTimeTicks);
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 2,
                ),
                child: Text(
                  '第 ${part.partIndex > 0 ? part.partIndex : '?'} 段',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    part.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (part.path.isNotEmpty)
                    Tooltip(
                      message: '双击复制路径',
                      child: GestureDetector(
                        onDoubleTap: () => _copyPath(context),
                        child: Text(
                          part.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (duration.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                duration,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// 列表成员只有精简字段，构造一个最小条目交给详情页，详情页会自行拉全量数据。
EmbyPcItem _partToItem(EmbyPcPartMember part) => EmbyPcItem(
  id: part.id,
  name: part.name,
  type: 'Movie',
  runTimeTicks: part.runTimeTicks,
  path: part.path,
  primaryImageTag: part.primaryImageTag,
  imageTags:
      part.primaryImageTag.isEmpty
          ? const {}
          : {'Primary': part.primaryImageTag},
);

String _partDurationLabel(int ticks) {
  if (ticks <= 0) return '';
  final duration = Duration(microseconds: ticks ~/ 10);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return duration.inHours > 0
      ? '${duration.inHours}:$minutes:$seconds'
      : '$minutes:$seconds';
}
