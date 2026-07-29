part of 'emby_pc_detail_page.dart';

// 文件、媒体流等结构化详情信息及格式化方法。
class _OtherInformation extends StatelessWidget {
  final EmbyPcItem detail;
  final EmbyPcMediaSource? source;

  const _OtherInformation({required this.detail, required this.source});

  @override
  Widget build(BuildContext context) {
    final mediaSource = source;
    final studioNames =
        detail.studios
            .map((studio) => studio.name)
            .where((name) => name.isNotEmpty)
            .toList();
    final mediaPath =
        mediaSource != null && mediaSource.path.isNotEmpty
            ? mediaSource.path
            : detail.path;
    final mediaLines =
        <String>[
          if (mediaPath.isNotEmpty) mediaPath,
          [
            if (mediaSource != null && mediaSource.container.isNotEmpty)
              mediaSource.container.toUpperCase(),
            if (mediaSource != null && mediaSource.size > 0)
              _fileSize(mediaSource.size),
          ].join('  '),
          if (detail.dateCreated.isNotEmpty)
            '添加于 ${_dateTimeLabel(detail.dateCreated)}',
        ].where((line) => line.isNotEmpty).toList();
    final cards = <Widget>[
      if (detail.genres.isNotEmpty)
        _InfoCard(
          title: '流派',
          icon: Icons.movie_filter_outlined,
          lines: [detail.genres.join('，')],
        ),
      if (detail.tags.isNotEmpty)
        _InfoCard(
          title: '标签',
          icon: Icons.sell_outlined,
          lines: [detail.tags.join('，')],
        ),
      if (studioNames.isNotEmpty)
        _InfoCard(
          title: '工作室',
          icon: Icons.business_outlined,
          lines: [studioNames.join('，')],
        ),
      _InfoCard(
        title: '媒体信息',
        icon: Icons.calendar_month_outlined,
        lines: mediaLines.isEmpty ? const ['暂无媒体信息'] : mediaLines,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '其它信息', icon: Icons.description_outlined),
        const SizedBox(height: 12),
        _ResponsiveCardGrid(children: cards),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> lines;

  const _InfoCard({
    required this.title,
    required this.icon,
    required this.lines,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardTitle(title: title, icon: icon),
            ...lines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  line,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 视频和音频流分别生成信息卡片，空字段在生成展示行时统一过滤。
class _StreamInformation extends StatelessWidget {
  final EmbyPcMediaSource source;

  const _StreamInformation({required this.source});

  @override
  Widget build(BuildContext context) {
    final streams =
        source.streams
            .where((stream) => stream.type == 'Video' || stream.type == 'Audio')
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '视频信息', icon: Icons.schedule_outlined),
        const SizedBox(height: 12),
        _ResponsiveCardGrid(
          children:
              streams
                  .map(
                    (stream) => _StreamCard(
                      title: stream.type == 'Video' ? '视频' : '音频',
                      icon:
                          stream.type == 'Video'
                              ? Icons.videocam_outlined
                              : Icons.headphones_outlined,
                      rows: _mediaStreamRows(stream),
                    ),
                  )
                  .toList(),
        ),
      ],
    );
  }
}

class _StreamCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<_InformationRow> rows;

  const _StreamCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardTitle(title: title, icon: icon),
            const SizedBox(height: 10),
            ...rows.map(
              (row) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        row.label,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        row.value,
                        style: const TextStyle(fontSize: 13, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 信息卡片标题与页面分区标题使用一致的 Windows 中文 UI 字体。
class _CardTitle extends StatelessWidget {
  final String title;
  final IconData icon;

  const _CardTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontFamily: 'Microsoft YaHei UI',
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

class _ResponsiveCardGrid extends StatelessWidget {
  final List<Widget> children;

  const _ResponsiveCardGrid({required this.children});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final cardWidth =
          constraints.maxWidth >= 600
              ? (constraints.maxWidth - 14) / 2
              : constraints.maxWidth;
      return Wrap(
        spacing: 14,
        runSpacing: 14,
        children:
            children
                .map((child) => SizedBox(width: cardWidth, child: child))
                .toList(),
      );
    },
  );
}

class _InformationRow {
  final String label;
  final String value;

  const _InformationRow(this.label, this.value);
}

// 仅为详情页横向列表补充鼠标拖动，不改变项目其它滚动区域的行为。
class _HorizontalDragScrollBehavior extends MaterialScrollBehavior {
  const _HorizontalDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

class _DetailImageRef {
  final String label;
  final String url;

  const _DetailImageRef({required this.label, required this.url});
}

// 图片预览提供缩放、滑动切换、左右按钮和关闭操作，不依赖额外组件库。

String _ticksLabel(int ticks) {
  final duration = Duration(microseconds: ticks ~/ 10);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return duration.inHours > 0
      ? '${duration.inHours}:$minutes:$seconds'
      : '$minutes:$seconds';
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

// 将详情图片标签转换为 Emby 图片地址，海报仍只用于页面顶部展示。
List<_DetailImageRef> _buildArtworkImages(EmbyPcItem detail) {
  final images = <_DetailImageRef>[];

  void addImage(String type, int index, String label) {
    images.add(
      _DetailImageRef(
        label: label,
        url: EmbyPcService.instance.imageUrl(
          detail.id,
          type: type,
          index: index,
          maxWidth: 1280,
        ),
      ),
    );
  }

  for (var index = 0; index < detail.backdropImageTags.length; index++) {
    addImage('Backdrop', index, '影片图片 ${index + 1}');
  }
  for (var index = 0; index < detail.screenshotImageTags.length; index++) {
    addImage('Screenshot', index, '艺术图 ${index + 1}');
  }
  const extraImages = <String, String>{
    'Art': '艺术图',
    'Thumb': '缩略图',
    'Banner': '横幅',
    'Logo': 'Logo',
    'Disc': '碟片',
  };
  for (final image in extraImages.entries) {
    final imageTag = detail.imageTags[image.key]?.toString() ?? '';
    if (imageTag.isNotEmpty) {
      addImage(image.key, 0, image.value);
    }
  }
  return images;
}

void _showArtworkPreview(
  BuildContext context,
  List<_DetailImageRef> images,
  int initialIndex,
) {
  showDialog<void>(
    context: context,
    builder:
        (_) =>
            _ArtworkPreviewDialog(images: images, initialIndex: initialIndex),
  );
}

String _personTypeLabel(EmbyPcPerson person) {
  if (person.type == 'Director') return '导演';
  if (person.type == 'Actor') return person.role.isEmpty ? '演员' : person.role;
  if (person.role.isNotEmpty) return person.role;
  return person.type.isEmpty ? '演职人员' : person.type;
}

String _dateTimeLabel(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final date = parsed.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${date.year}/${twoDigits(date.month)}/${twoDigits(date.day)} '
      '${twoDigits(date.hour)}:${twoDigits(date.minute)}';
}

// 根据流类型生成信息行，接口未返回的空字段不会占据卡片空间。
List<_InformationRow> _mediaStreamRows(EmbyPcMediaStream stream) {
  final rows = <_InformationRow>[];

  void add(String label, String value) {
    if (value.isNotEmpty) rows.add(_InformationRow(label, value));
  }

  add('标题', stream.title);
  if (stream.type == 'Video') {
    add('编解码器', stream.codec);
    add('编解码器标签', stream.codecTag);
    add('用户配置', stream.profile);
    add('等级', stream.level?.toString() ?? '');
    add(
      '分辨率',
      stream.width != null && stream.height != null
          ? '${stream.width}x${stream.height}'
          : '',
    );
    add('长宽比', stream.aspectRatio);
    add('交错', _booleanLabel(stream.isInterlaced));
    add('帧率', _numberLabel(stream.averageFrameRate ?? stream.realFrameRate));
    add('比特率', _bitrateLabel(stream.bitrate));
    add('基色', stream.colorPrimaries);
    add('色域', stream.colorSpace);
    add('色彩转换', stream.colorTransfer);
    add('位深度', stream.bitDepth == null ? '' : '${stream.bitDepth} bit');
    add('像素格式', stream.pixelFormat);
    add('参考帧', stream.refFrames?.toString() ?? '');
  } else {
    add('语言', stream.language);
    add('编解码器', stream.codec);
    add('编解码器标签', stream.codecTag);
    add('用户配置', stream.profile);
    add('布局', stream.channelLayout);
    add('频道', stream.channels == null ? '' : '${stream.channels} ch');
    add('比特率', _bitrateLabel(stream.bitrate));
    add('采样率', stream.sampleRate == null ? '' : '${stream.sampleRate} Hz');
    add('默认', _booleanLabel(stream.isDefault));
  }
  return rows;
}

String _numberLabel(double? value) {
  if (value == null) return '';
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
}

String _bitrateLabel(int? bitrate) {
  if (bitrate == null || bitrate <= 0) return '';
  if (bitrate >= 1000000) return '${(bitrate / 1000000).round()} mbps';
  if (bitrate >= 1000) return '${(bitrate / 1000).round()} kbps';
  return '$bitrate bps';
}

String _booleanLabel(bool? value) {
  if (value == null) return '';
  return value ? '是' : '否';
}
