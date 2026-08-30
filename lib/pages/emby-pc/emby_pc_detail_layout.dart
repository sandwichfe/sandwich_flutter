part of 'emby_pc_detail_page.dart';

// 详情页骨架、摘要和通用状态视图。
class _DetailBackdrop extends StatelessWidget {
  final EmbyPcItem item;
  final Duration duration;

  const _DetailBackdrop({required this.item, required this.duration});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final url =
        item.hasBackdropImage
            ? EmbyPcService.instance.imageUrl(
              item.id,
              type: 'Backdrop',
              maxWidth: 1600,
            )
            : item.hasPrimaryImage
            ? EmbyPcService.instance.imageUrl(item.id, maxWidth: 1000)
            : '';
    return ExcludeSemantics(
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child:
            url.isEmpty
                ? ColoredBox(
                  key: const ValueKey('detail-backdrop-empty'),
                  color: colors.surfaceContainerLowest,
                )
                : SizedBox.expand(
                  key: ValueKey(url),
                  child: EmbyPcNetworkImage(url: url),
                ),
      ),
    );
  }
}

class _DetailContent extends StatelessWidget {
  final EmbyPcItem detail;
  final List<EmbyPcItem> similar;
  final bool favoriteBusy;
  final bool actionBusy;
  final VoidCallback onFavorite;
  final ValueChanged<EmbyPcMediaAction> onAction;
  final void Function(int? ticks, String? mediaSourceId) onPlay;
  final ValueChanged<String> onSelectMediaSource;
  final ValueChanged<EmbyPcItem> onOpenSimilar;
  final ValueChanged<EmbyPcPerson> onOpenPerson;

  const _DetailContent({
    required this.detail,
    required this.similar,
    required this.favoriteBusy,
    required this.actionBusy,
    required this.onFavorite,
    required this.onAction,
    required this.onPlay,
    required this.onSelectMediaSource,
    required this.onOpenSimilar,
    required this.onOpenPerson,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      // 参考桌面端仅展示演员和导演，避免其它幕后人员挤占横向列表。
      final creditPeople =
          detail.people
              .where(
                (person) => person.type == 'Actor' || person.type == 'Director',
              )
              .toList();
      final artworkImages = _buildArtworkImages(detail);
      final summary = _Summary(
        detail: detail,
        onFavorite: onFavorite,
        favoriteBusy: favoriteBusy,
        actionBusy: actionBusy,
        onAction: onAction,
        onPlay: onPlay,
        onSelectMediaSource: onSelectMediaSource,
      );
      // Primary 竖版海报保留在标题旁，和页面背景使用的 Backdrop 区分展示。
      final poster = SizedBox(
        width: wide ? 230 : 180,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: EmbyPcNetworkImage(
              url:
                  detail.hasPrimaryImage
                      ? EmbyPcService.instance.imageUrl(
                        detail.id,
                        maxWidth: 500,
                      )
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
              children: [
                poster,
                const SizedBox(width: 28),
                Expanded(child: summary),
              ],
            )
          else ...[
            Center(child: poster),
            const SizedBox(height: 22),
            summary,
          ],
          if (detail.chapters.isNotEmpty) ...[
            const SizedBox(height: 32),
            const _SectionTitle(
              title: '章节',
              icon: Icons.play_circle_outline_rounded,
            ),
            const SizedBox(height: 12),
            // 使用 Emby 生成的 Chapter 图片展示章节，点击后从对应时间开始播放。
            _ChapterCarousel(
              itemId: detail.id,
              chapters: detail.chapters,
              onPlay: (ticks) => onPlay(ticks, null),
            ),
          ],
          if (artworkImages.isNotEmpty) ...[
            const SizedBox(height: 32),
            _ArtworkSection(images: artworkImages),
          ],
          if (creditPeople.isNotEmpty) ...[
            const SizedBox(height: 32),
            _CastSection(people: creditPeople, onOpenPerson: onOpenPerson),
          ],
          if (similar.isNotEmpty) ...[
            const SizedBox(height: 32),
            _SimilarSection(items: similar, onOpenItem: onOpenSimilar),
          ],
          const SizedBox(height: 32),
          _OtherInformation(
            detail: detail,
            source:
                detail.mediaSources.isEmpty ? null : detail.mediaSources.first,
          ),
          if (detail.mediaSources.isNotEmpty &&
              detail.mediaSources.first.streams.any(
                (stream) => stream.type == 'Video' || stream.type == 'Audio',
              )) ...[
            const SizedBox(height: 32),
            _StreamInformation(source: detail.mediaSources.first),
          ],
        ],
      );
    },
  );
}

// 章节区域保留横向滑动，并在桌面端悬停时显示左右滚动按钮。

class _Summary extends StatelessWidget {
  final EmbyPcItem detail;
  final bool favoriteBusy;
  final bool actionBusy;
  final VoidCallback onFavorite;
  final ValueChanged<EmbyPcMediaAction> onAction;
  final void Function(int? ticks, String? mediaSourceId) onPlay;
  final ValueChanged<String> onSelectMediaSource;

  const _Summary({
    required this.detail,
    required this.favoriteBusy,
    required this.actionBusy,
    required this.onFavorite,
    required this.onAction,
    required this.onPlay,
    required this.onSelectMediaSource,
  });

  EmbyPcMediaStream? _preferredStream(String type) {
    if (detail.mediaSources.isEmpty) return null;
    EmbyPcMediaStream? first;
    for (final stream in detail.mediaSources.first.streams) {
      if (stream.type != type) continue;
      first ??= stream;
      if (stream.isDefault == true) return stream;
    }
    return first;
  }

  String _typeLabel() => switch (detail.type) {
    'Movie' => '电影',
    'Episode' => '剧集',
    'Series' => '剧集',
    'Video' => '视频',
    'MusicVideo' => '音乐视频',
    'Trailer' => '预告片',
    _ => detail.type,
  };

  String _formatPosition(int ticks) {
    final duration = Duration(microseconds: ticks ~/ 10);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  String _endingTimeLabel() {
    if (detail.runTimeTicks <= 0) return '';
    final playedTicks =
        detail.playbackPositionTicks.clamp(0, detail.runTimeTicks).toInt();
    final remaining = Duration(
      microseconds: (detail.runTimeTicks - playedTicks) ~/ 10,
    );
    final endingAt = DateTime.now().add(remaining);
    final hour = endingAt.hour.toString().padLeft(2, '0');
    final minute = endingAt.minute.toString().padLeft(2, '0');
    return '结束于 $hour:$minute';
  }

  String _videoLabel(EmbyPcMediaStream? stream) {
    if (stream == null) return '';
    final width = stream.width ?? detail.width ?? 0;
    final height = stream.height ?? detail.height ?? 0;
    final quality = switch ((width, height)) {
      (>= 3800, _) || (_, >= 2000) => '4K',
      (>= 1900, _) || (_, >= 1000) => '1080P',
      (>= 1200, _) || (_, >= 700) => '720P',
      (> 0, _) || (_, > 0) => 'SD',
      _ => '',
    };
    return [
      quality,
      if (stream.codec.isNotEmpty) stream.codec.toUpperCase(),
    ].where((value) => value.isNotEmpty).join(' ');
  }

  String _audioLabel(EmbyPcMediaStream? stream) {
    if (stream == null) return '';
    final channelLabel =
        stream.channelLayout.isNotEmpty
            ? stream.channelLayout
            : switch (stream.channels) {
              1 => 'mono',
              2 => 'stereo',
              6 => '5.1',
              8 => '7.1',
              int channels => '$channels 声道',
              _ => '',
            };
    return [
      if (stream.codec.isNotEmpty) stream.codec.toUpperCase(),
      channelLabel,
      if (stream.isDefault == true) '(默认)',
    ].where((value) => value.isNotEmpty).join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final meta = <String>[
      if (detail.productionYear != null) '${detail.productionYear}',
      if (detail.officialRating.isNotEmpty) detail.officialRating,
      if (detail.communityRating != null)
        '★ ${detail.communityRating!.toStringAsFixed(1)}',
    ];
    final videoStream = _preferredStream('Video');
    final audioStream = _preferredStream('Audio');
    final mediaMeta =
        <String>[
          _typeLabel(),
          detail.runtimeLabel,
          _endingTimeLabel(),
          _videoLabel(videoStream),
          _audioLabel(audioStream),
        ].where((value) => value.isNotEmpty).toList();
    final playedTicks =
        detail.runTimeTicks > 0
            ? detail.playbackPositionTicks.clamp(0, detail.runTimeTicks).toInt()
            : 0;
    final hasPlaybackProgress = playedTicks > 0;
    final playbackProgress =
        hasPlaybackProgress ? playedTicks / detail.runTimeTicks : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          detail.name,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            // 媒体主标题沿用分区标题的字体，保持详情页视觉统一。
            fontFamily: 'Microsoft YaHei UI',
            fontWeight: FontWeight.w600,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(meta.join('  ·  ')),
        ],
        // 只要服务端返回媒体源就显示版本选择器，单版本默认选中首项。
        if (detail.mediaSources.isNotEmpty) ...[
          const SizedBox(height: 10),
          _MediaSourcesSection(
            sources: detail.mediaSources,
            onSelect: onSelectMediaSource,
          ),
        ],
        if (mediaMeta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            mediaMeta.join('   '),
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
        if (hasPlaybackProgress) ...[
          const SizedBox(height: 18),
          // 续播位置与百分比同时展示，避免用户只能依靠进度条估算。
          Row(
            children: [
              Expanded(
                child: Text(
                  '上次播放至 ${_formatPosition(playedTicks)}'
                  ' / ${_formatPosition(detail.runTimeTicks)}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${(playbackProgress * 100).round()}%',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: playbackProgress,
              minHeight: 5,
              color: colors.primary,
              backgroundColor: colors.surfaceContainerHighest,
            ),
          ),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () => onPlay(null, null),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(detail.playbackPositionTicks > 0 ? '继续播放' : '播放'),
            ),
            OutlinedButton.icon(
              onPressed: favoriteBusy ? null : onFavorite,
              icon:
                  favoriteBusy
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
            PopupMenuButton<EmbyPcMediaAction>(
              tooltip: '更多',
              enabled: !actionBusy,
              onSelected: onAction,
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: EmbyPcMediaAction.editMetadata,
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('编辑元数据'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: EmbyPcMediaAction.editImages,
                  child: Row(
                    children: [
                      Icon(Icons.image_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('编辑图像'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: EmbyPcMediaAction.refreshMetadata,
                  child: Row(
                    children: [
                      Icon(Icons.refresh_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('刷新元数据'),
                    ],
                  ),
                ),
              ],
              child: SizedBox.square(
                dimension: 40,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: actionBusy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.more_horiz),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (detail.overview.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(detail.overview, style: const TextStyle(height: 1.65)),
        ],
      ],
    );
  }
}

// 媒体源使用紧凑下拉选择器展示，单版本时仍显示当前默认源。
class _MediaSourcesSection extends StatelessWidget {
  final List<EmbyPcMediaSource> sources;
  final ValueChanged<String> onSelect;

  const _MediaSourcesSection({required this.sources, required this.onSelect});

  String _sourceTitle(EmbyPcMediaSource source, int index) {
    final name = source.name.trim();
    return name.isEmpty ? '版本 ${index + 1}' : name;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 服务端将首个媒体源作为当前默认版本，胶囊和菜单勾选保持一致。
    final selectedSource = sources.first;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('版本', style: TextStyle(color: colors.onSurfaceVariant)),
        const SizedBox(width: 10),
        // 窄屏时下拉选择器可在标签后的剩余宽度内收缩，避免右侧内容溢出。
        Flexible(
          child: PopupMenuButton<String?>(
            tooltip: '选择媒体版本',
            offset: const Offset(0, 8),
            position: PopupMenuPosition.under,
            color: colors.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            onSelected: (mediaSourceId) {
              if (mediaSourceId != null && mediaSourceId.isNotEmpty) {
                onSelect(mediaSourceId);
              }
            },
            itemBuilder: (context) => [
              for (var index = 0; index < sources.length; index++)
                PopupMenuItem<String?>(
                  value: sources[index].id.isEmpty ? null : sources[index].id,
                  child: Row(
                    children: [
                      Icon(
                        Icons.check,
                        color: sources[index].id == selectedSource.id
                            ? colors.onSurface
                            : Colors.transparent,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _sourceTitle(sources[index], index),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            child: ConstrainedBox(
              // 保持桌面端原有最大宽度，同时将移动端可用宽度传递给标题。
              constraints: const BoxConstraints(maxWidth: 310),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(14, 7, 10, 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _sourceTitle(selectedSource, 0),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// 分区标题可按需携带图标，并使用适合 Windows 中文界面的系统 UI 字体。
class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData? icon;

  const _SectionTitle({required this.title, this.icon});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
      Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          // 微软雅黑 UI 是 Windows 主流中文桌面产品常用的清晰无衬线字体。
          fontFamily: 'Microsoft YaHei UI',
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
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
