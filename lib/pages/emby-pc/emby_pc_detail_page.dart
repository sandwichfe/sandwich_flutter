import 'package:flutter/material.dart';

import 'emby_pc_models.dart';
import 'emby_pc_person_page.dart';
import 'emby_pc_player_page.dart';
import 'emby_pc_service.dart';
import 'emby_pc_widgets.dart';

class EmbyPcDetailPage extends StatefulWidget {
  final EmbyPcItem item;

  const EmbyPcDetailPage({super.key, required this.item});

  @override
  State<EmbyPcDetailPage> createState() => _EmbyPcDetailPageState();
}

class _EmbyPcDetailPageState extends State<EmbyPcDetailPage> {
  EmbyPcItem? _detail;
  List<EmbyPcItem> _similar = const [];
  bool _loading = true;
  bool _favoriteBusy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final results = await Future.wait<dynamic>([
        EmbyPcService.instance.getItemDetail(widget.item.id),
        EmbyPcService.instance.getSimilarItems(widget.item.id),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as EmbyPcItem;
        _similar = results[1] as List<EmbyPcItem>;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final detail = _detail;
    if (detail == null || _favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    try {
      final value = await EmbyPcService.instance.setFavorite(
        detail.id,
        !detail.isFavorite,
      );
      if (mounted) setState(() => _detail = detail.copyWith(isFavorite: value));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  void _play([int? positionTicks]) {
    final detail = _detail;
    if (detail == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmbyPcPlayerPage(
          item: detail,
          startPositionTicks: positionTicks ?? detail.playbackPositionTicks,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? _DetailError(message: _error, onRetry: _loadDetail)
              : detail == null
                  ? const Center(child: Text('没有可显示的媒体详情'))
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        // 将媒体图片铺满页面作为固定背景，优先展示更适合宽屏的背景图。
                        EmbyPcNetworkImage(
                          url: detail.hasBackdropImage
                              ? EmbyPcService.instance.imageUrl(
                                  detail.id,
                                  type: 'Backdrop',
                                  maxWidth: 1600,
                                )
                              : detail.hasPrimaryImage
                                  ? EmbyPcService.instance.imageUrl(
                                      detail.id,
                                      maxWidth: 1000,
                                    )
                                  : '',
                        ),
                        // 使用主题色渐变压暗图片，保证浅色和深色主题下的正文都清晰可读。
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                colors.surface.withOpacity(0.58),
                                colors.surface.withOpacity(0.86),
                                colors.surface.withOpacity(0.98),
                              ],
                              stops: const [0, 0.48, 1],
                            ),
                          ),
                        ),
                        CustomScrollView(
                          slivers: [
                            SliverAppBar(
                              pinned: true,
                              backgroundColor: colors.surface.withOpacity(0.78),
                              title: Text(detail.name),
                            ),
                            SliverToBoxAdapter(
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 1180),
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: _DetailContent(
                                      detail: detail,
                                      similar: _similar,
                                      favoriteBusy: _favoriteBusy,
                                      onFavorite: _toggleFavorite,
                                      onPlay: _play,
                                      onOpenSimilar: (item) => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => EmbyPcDetailPage(item: item),
                                        ),
                                      ),
                                      onOpenPerson: (person) => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => EmbyPcPersonPage(
                                            personId: person.id,
                                            personName: person.name,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
    );
  }
}

class _DetailContent extends StatelessWidget {
  final EmbyPcItem detail;
  final List<EmbyPcItem> similar;
  final bool favoriteBusy;
  final VoidCallback onFavorite;
  final void Function(int? ticks) onPlay;
  final ValueChanged<EmbyPcItem> onOpenSimilar;
  final ValueChanged<EmbyPcPerson> onOpenPerson;

  const _DetailContent({
    required this.detail,
    required this.similar,
    required this.favoriteBusy,
    required this.onFavorite,
    required this.onPlay,
    required this.onOpenSimilar,
    required this.onOpenPerson,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      final summary = _Summary(
        detail: detail,
        onFavorite: onFavorite,
        favoriteBusy: favoriteBusy,
        onPlay: onPlay,
      );
      // Primary 竖版海报保留在标题旁，和页面背景使用的 Backdrop 区分展示。
      final poster = SizedBox(
        width: wide ? 230 : 180,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: EmbyPcNetworkImage(
              url: detail.hasPrimaryImage
                  ? EmbyPcService.instance.imageUrl(detail.id, maxWidth: 500)
                  : '',
            ),
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 宽屏时海报位于标题左侧，窄屏时保持原有的上下排列。
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [poster, const SizedBox(width: 28), Expanded(child: summary)],
            )
          else ...[
            Center(child: poster),
            const SizedBox(height: 22),
            summary,
          ],
          if (detail.chapters.isNotEmpty) ...[
            const SizedBox(height: 32),
            _SectionTitle(title: '章节'),
            const SizedBox(height: 12),
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: detail.chapters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final chapter = detail.chapters[index];
                  return ActionChip(
                    avatar: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(
                      '${chapter.name.isEmpty ? '章节 ${index + 1}' : chapter.name}  '
                      '${_ticksLabel(chapter.startPositionTicks)}',
                    ),
                    onPressed: () => onPlay(chapter.startPositionTicks),
                  );
                },
              ),
            ),
          ],
          if (detail.people.isNotEmpty) ...[
            const SizedBox(height: 26),
            _SectionTitle(title: '演职人员'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: detail.people
                  .where((person) => person.id.isNotEmpty)
                  .map(
                    (person) => ActionChip(
                      avatar: const Icon(Icons.person_outline, size: 18),
                      label: Text(
                        person.role.isEmpty
                            ? person.name
                            : '${person.name} · ${person.role}',
                      ),
                      onPressed: () => onOpenPerson(person),
                    ),
                  )
                  .toList(),
            ),
          ],
          if (detail.mediaSources.isNotEmpty) ...[
            const SizedBox(height: 26),
            _MediaInformation(source: detail.mediaSources.first),
          ],
          if (similar.isNotEmpty) ...[
            const SizedBox(height: 32),
            _SectionTitle(title: '更多类似'),
            const SizedBox(height: 12),
            SizedBox(
              height: 250,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: similar.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => SizedBox(
                  width: 160,
                  child: EmbyPcMediaTile(
                    item: similar[index],
                    imageStyle: 'poster',
                    onOpen: () => onOpenSimilar(similar[index]),
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _Summary extends StatelessWidget {
  final EmbyPcItem detail;
  final bool favoriteBusy;
  final VoidCallback onFavorite;
  final void Function(int? ticks) onPlay;

  const _Summary({
    required this.detail,
    required this.favoriteBusy,
    required this.onFavorite,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      if (detail.productionYear != null) '${detail.productionYear}',
      if (detail.officialRating.isNotEmpty) detail.officialRating,
      if (detail.runtimeLabel.isNotEmpty) detail.runtimeLabel,
      if (detail.communityRating != null)
        '★ ${detail.communityRating!.toStringAsFixed(1)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          detail.name,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(meta.join('  ·  ')),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () => onPlay(null),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(
                detail.playbackPositionTicks > 0 ? '继续播放' : '播放',
              ),
            ),
            OutlinedButton.icon(
              onPressed: favoriteBusy ? null : onFavorite,
              icon: favoriteBusy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      detail.isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                    ),
              label: Text(detail.isFavorite ? '已收藏' : '收藏'),
            ),
          ],
        ),
        if (detail.overview.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(detail.overview, style: const TextStyle(height: 1.65)),
        ],
        if (detail.genres.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('类型：${detail.genres.join('、')}'),
        ],
        if (detail.studios.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '制作：${detail.studios.map((item) => item.name).where((name) => name.isNotEmpty).join('、')}',
          ),
        ],
      ],
    );
  }
}

class _MediaInformation extends StatelessWidget {
  final EmbyPcMediaSource source;

  const _MediaInformation({required this.source});

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('媒体信息', style: TextStyle(fontWeight: FontWeight.w600)),
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 18,
          runSpacing: 8,
          children: [
            if (source.container.isNotEmpty) Text('容器：${source.container}'),
            if (source.size > 0) Text('大小：${_fileSize(source.size)}'),
            if (source.bitrate > 0)
              Text('码率：${(source.bitrate / 1000000).toStringAsFixed(1)} Mbps'),
            ...source.streams.map((stream) {
              final detail = <String>[
                stream.codec,
                if (stream.width != null && stream.height != null)
                  '${stream.width}x${stream.height}',
                if (stream.language.isNotEmpty) stream.language,
                if (stream.channels != null) '${stream.channels} ch',
              ].where((value) => value.isNotEmpty).join(' · ');
              return Text('${stream.type}：$detail');
            }),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: Theme.of(context).textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
    ),
  );
}

class _DetailError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _DetailError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 48),
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

String _ticksLabel(int ticks) {
  final duration = Duration(microseconds: ticks ~/ 10);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return duration.inHours > 0 ? '${duration.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}

String _fileSize(int size) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}
