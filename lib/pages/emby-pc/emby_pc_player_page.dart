import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';

class EmbyPcPlayerPage extends StatefulWidget {
  final EmbyPcItem item;
  final int startPositionTicks;

  const EmbyPcPlayerPage({
    super.key,
    required this.item,
    this.startPositionTicks = 0,
  });

  @override
  State<EmbyPcPlayerPage> createState() => _EmbyPcPlayerPageState();
}

class _EmbyPcPlayerPageState extends State<EmbyPcPlayerPage> {
  late final Player _player;
  late final VideoController _videoController;
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  bool _loading = true;
  bool _muted = false;
  double _volume = 100.0;
  double _volumeBeforeMute = 100.0;
  String _error = '';
  bool _playerReady = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _aspectRatio = 16 / 9;
  Timer? _progressTimer;
  late final _ThumbnailPreviewController _thumbnailPreviewController;

  @override
  void initState() {
    super.initState();
    // Use Emby's known dimensions while the native decoder is still loading.
    if (widget.item.width != null &&
        widget.item.height != null &&
        widget.item.height! > 0) {
      _aspectRatio = widget.item.width! / widget.item.height!;
    }
    _player = Player();
    _videoController = VideoController(_player);
    // 缩略图数据与控制层状态分离，后续可在这里接入其他 Emby 预览来源。
    _thumbnailPreviewController = _ThumbnailPreviewController();
    _listenToPlayerState();
    _initializePlayer();
  }

  // Keep the Flutter controls synchronized with media_kit's event streams.
  void _listenToPlayerState() {
    _playerSubscriptions.add(
      _player.stream.playing.listen((playing) {
        if (mounted) setState(() => _isPlaying = playing);
      }),
    );
    _playerSubscriptions.add(
      _player.stream.position.listen((position) {
        if (mounted) setState(() => _position = position);
      }),
    );
    _playerSubscriptions.add(
      _player.stream.duration.listen((duration) {
        if (mounted) setState(() => _duration = duration);
      }),
    );
    // 音量状态由播放器事件统一回写，保证按钮、滑条和底层实际音量一致。
    _playerSubscriptions.add(
      _player.stream.volume.listen((volume) {
        if (!mounted) return;
        final safeVolume = volume.clamp(0.0, 100.0).toDouble();
        setState(() {
          _volume = safeVolume;
          _muted = safeVolume <= 0;
          if (safeVolume > 0) _volumeBeforeMute = safeVolume;
        });
      }),
    );
    _playerSubscriptions.add(
      _player.stream.videoParams.listen((params) {
        final aspect =
            params.aspect ??
            (params.dw != null && params.dh != null && params.dh! > 0
                ? params.dw! / params.dh!
                : null);
        if (mounted && aspect != null && aspect > 0) {
          setState(() => _aspectRatio = aspect);
        }
      }),
    );
    _playerSubscriptions.add(
      _player.stream.error.listen((message) {
        if (message.isEmpty || !mounted) return;
        setState(() {
          _loading = false;
          _playerReady = false;
          _error = '视频加载失败: $message';
        });
      }),
    );
  }

  // 章节和继续播放都换算为 Emby ticks 后从指定位置起播。
  Future<void> _initializePlayer() async {
    try {
      final start = Duration(microseconds: widget.startPositionTicks ~/ 10);
      final hasKnownDuration = widget.item.duration > Duration.zero;
      final startPosition =
          start > Duration.zero &&
                  (!hasKnownDuration || start < widget.item.duration)
              ? start
              : null;
      final media = Media(
        EmbyPcService.instance.streamUrl(widget.item.id),
        start: startPosition,
      );
      await _player.open(media);
      if (!mounted) {
        await _player.dispose();
        return;
      }
      if (_error.isNotEmpty) return;
      _progressTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _reportProgress('/Sessions/Playing/Progress'),
      );
      _reportProgress('/Sessions/Playing');
      setState(() {
        _loading = false;
        _playerReady = true;
        _isPlaying = _player.state.playing;
        _position = _player.state.position;
        _duration = _player.state.duration;
      });
      // 预览图独立异步加载，避免 BIF 不可用时阻塞视频起播。
      unawaited(_loadBifPreview());
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '视频加载失败：$error';
        });
      }
    }
  }

  Future<void> _loadBifPreview() async {
    final bytes = await EmbyPcService.instance.getBifPreview(widget.item.id);
    if (!mounted || bytes == null) return;

    try {
      final previewData = _BifPreviewData.parse(bytes);
      if (mounted) {
        setState(() => _thumbnailPreviewController.updateData(previewData));
      }
    } catch (_) {
      // BIF 缺失或格式异常只关闭进度预览，不影响当前视频播放。
    }
  }

  void _reportProgress(String eventPath) {
    final ticks = _player.state.position.inMicroseconds * 10;
    EmbyPcService.instance.reportPlayback(
      itemId: widget.item.id,
      eventPath: eventPath,
      positionTicks: ticks,
      paused: !_player.state.playing,
    );
  }

  Future<void> _togglePlay() async {
    if (!_playerReady) return;
    _isPlaying ? await _player.pause() : await _player.play();
    _reportProgress('/Sessions/Playing/Progress');
  }

  Future<void> _toggleMute() async {
    if (!_playerReady) return;
    // 取消静音时恢复用户最近一次设置的音量，不强制跳回满音量。
    final targetVolume = _muted ? _volumeBeforeMute : 0.0;
    setState(() {
      if (!_muted && _volume > 0) _volumeBeforeMute = _volume;
      _volume = targetVolume;
      _muted = targetVolume <= 0;
    });
    await _player.setVolume(targetVolume);
  }

  Future<void> _setVolume(double volume) async {
    if (!_playerReady) return;
    final safeVolume = volume.clamp(0.0, 100.0).toDouble();
    // 拖动到零时同步显示静音，重新增大音量时恢复对应音量图标。
    setState(() {
      _volume = safeVolume;
      _muted = safeVolume <= 0;
      if (safeVolume > 0) _volumeBeforeMute = safeVolume;
    });
    await _player.setVolume(safeVolume);
  }

  @override
  void dispose() {
    if (_playerReady) _reportProgress('/Sessions/Playing/Stopped');
    _progressTimer?.cancel();
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    _thumbnailPreviewController.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.item.name, overflow: TextOverflow.ellipsis),
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _error.isNotEmpty
              ? Center(
                child: _PlayerMessage(
                  icon: Icons.error_outline,
                  text: _error,
                ),
              )
              : !_playerReady
              ? const Center(
                child: _PlayerMessage(
                  icon: Icons.videocam_off_outlined,
                  text: '播放器不可用',
                ),
              )
              : SizedBox.expand(
                // 播放器视口铺满页面，画面在视口内保持比例，控制层始终吸附视口底部。
                child: Video(
                  controller: _videoController,
                  aspectRatio: _aspectRatio,
                  fit: BoxFit.contain,
                  // 仅将画面在剩余黑边中轻微上移，控制栏仍固定在播放器底部。
                  alignment: const Alignment(0, -0.22),
                  // Flutter 字幕上移到控制区上方，避免与进度条和操作按钮重叠。
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 104),
                  ),
                  // Render the custom controls inside Video as its only
                  // control layer instead of stacking a second outer bar.
                  // 控制层自身占满播放器，再在内部固定到底部，避免 Align 的松约束
                  // 让进度条、预览框在不同窗口比例下出现错位。
                  controls:
                      (_) => _PlayerControls(
                        player: _player,
                        position: _position,
                        duration: _duration,
                        isPlaying: _isPlaying,
                        thumbnailPreviewController:
                            _thumbnailPreviewController,
                        muted: _muted,
                        volume: _volume,
                        onTogglePlay: _togglePlay,
                        onToggleMute: _toggleMute,
                        onVolumeChanged:
                            (value) => unawaited(_setVolume(value)),
                      ),
                ),
              ),
    );
  }
}

class _BifPreviewFrame {
  final int timestampMs;
  final int offset;
  final int nextOffset;

  const _BifPreviewFrame({
    required this.timestampMs,
    required this.offset,
    required this.nextOffset,
  });
}

class _BifPreviewData {
  final Uint8List bytes;
  final List<_BifPreviewFrame> frames;

  const _BifPreviewData({required this.bytes, required this.frames});

  // BIF 使用小端序索引，每个索引项保存时间戳和对应 JPEG 的起始偏移。
  factory _BifPreviewData.parse(Uint8List bytes) {
    const headerLength = 64;
    const indexEntryLength = 8;
    if (bytes.length < headerLength + indexEntryLength * 2) {
      throw const FormatException('BIF preview file is too small');
    }
    if (bytes[1] != 0x42 || bytes[2] != 0x49 || bytes[3] != 0x46) {
      throw const FormatException('Invalid BIF preview header');
    }

    final view = ByteData.sublistView(bytes);
    final declaredFrameCount = view.getUint32(12, Endian.little);
    final declaredMultiplier = view.getUint32(16, Endian.little);
    final timestampMultiplier =
        declaredMultiplier == 0 ? 1000 : declaredMultiplier;
    final maxFrameCount = math.max(
      0,
      ((bytes.length - headerLength) ~/ indexEntryLength) - 1,
    );
    final frameCount = math.min(declaredFrameCount, maxFrameCount);
    final frames = <_BifPreviewFrame>[];

    for (var index = 0; index < frameCount; index += 1) {
      final entryOffset = headerLength + index * indexEntryLength;
      final nextEntryOffset = entryOffset + indexEntryLength;
      final timestamp = view.getUint32(entryOffset, Endian.little);
      final offset = view.getUint32(entryOffset + 4, Endian.little);
      final nextOffset = view.getUint32(nextEntryOffset + 4, Endian.little);
      if (timestamp == 0xffffffff ||
          offset >= nextOffset ||
          nextOffset > bytes.length) {
        continue;
      }
      frames.add(
        _BifPreviewFrame(
          timestampMs: timestamp * timestampMultiplier,
          offset: offset,
          nextOffset: nextOffset,
        ),
      );
    }

    if (frames.isEmpty) {
      throw const FormatException('BIF preview has no valid frames');
    }
    return _BifPreviewData(bytes: bytes, frames: List.unmodifiable(frames));
  }

  // 二分查找不晚于目标时间的最近一帧，保证拖动时无需顺序扫描全部索引。
  int findFrameIndex(int targetMs) {
    var low = 0;
    var high = frames.length - 1;
    var result = 0;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (frames[middle].timestampMs <= targetMs) {
        result = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return result;
  }

  Uint8List frameBytes(int index) {
    final frame = frames[index];
    return Uint8List.sublistView(bytes, frame.offset, frame.nextOffset);
  }
}

class _ThumbnailPreviewFrame {
  final int index;
  final Uint8List imageBytes;

  const _ThumbnailPreviewFrame({
    required this.index,
    required this.imageBytes,
  });
}

class _ThumbnailPreviewController {
  final Map<int, Uint8List> _frameCache = {};
  _BifPreviewData? _previewData;
  int _revision = 0;

  bool get isAvailable => _previewData != null;
  int get revision => _revision;

  // 当前先使用已加载的 BIF；以后接入 Trickplay 时仍由该控制器统一提供图片。
  void updateData(_BifPreviewData previewData) {
    _previewData = previewData;
    _frameCache.clear();
    _revision += 1;
  }

  _ThumbnailPreviewFrame? getThumbnailAt(Duration position) {
    final previewData = _previewData;
    if (previewData == null) return null;

    final index = previewData.findFrameIndex(position.inMilliseconds);
    // 同一缩略帧复用字节视图，避免播放器频繁刷新时重复解析图片。
    final imageBytes = _frameCache.putIfAbsent(
      index,
      () => previewData.frameBytes(index),
    );
    return _ThumbnailPreviewFrame(index: index, imageBytes: imageBytes);
  }

  void clear() {
    _previewData = null;
    _frameCache.clear();
    _revision += 1;
  }
}

class _PlayerControls extends StatelessWidget {
  final Player player;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final _ThumbnailPreviewController thumbnailPreviewController;
  final bool muted;
  final double volume;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolumeChanged;

  const _PlayerControls({
    required this.player,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.thumbnailPreviewController,
    required this.muted,
    required this.volume,
    required this.onTogglePlay,
    required this.onToggleMute,
    required this.onVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 点击视频画面切换播放状态；底部控制栏位于该层上方，仍可独立响应操作。
        Positioned.fill(
          child: Semantics(
            button: true,
            label: isPlaying ? '暂停' : '播放',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTogglePlay,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child:
                        isPlaying
                            ? const SizedBox.shrink(key: ValueKey('playing'))
                            : Container(
                              key: const ValueKey('paused'),
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                // 半透明白色按钮兼顾不同亮度视频画面的可读性。
                                color: const Color(0x2EFFFFFF),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xB3FFFFFF),
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black38,
                                    blurRadius: 24,
                                    offset: Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 46,
                              ),
                            ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 渐变只负责增强工具可读性，不拦截视频区域的鼠标与触摸事件。
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 160,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xD9000000)],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 520;
                final horizontalPadding = compact ? 4.0 : 8.0;
                final timeText =
                    constraints.maxWidth < 380
                        ? _formatDuration(position)
                        : '${_formatDuration(position)} / '
                            '${_formatDuration(duration)}';
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 时间轴只保留极窄的窗口边距，下方按钮继续使用舒适的操作间距。
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: _PreviewTimelineBar(
                        position: position,
                        duration: duration,
                        thumbnailController: thumbnailPreviewController,
                        onSeek: (value) => unawaited(player.seek(value)),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: isPlaying ? '暂停' : '播放',
                            color: Colors.white,
                            visualDensity: VisualDensity.compact,
                            onPressed: onTogglePlay,
                            icon: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          const SizedBox(width: 4),
                          // 时间区域独占剩余空间，右侧操作区因此始终贴住窗口右边。
                          Expanded(
                            child: Text(
                              timeText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                          // 右侧操作区保持贴右；竖向音量层不参与控制栏宽度分配。
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _VolumeControl(
                                volume: volume,
                                muted: muted,
                                compact: compact,
                                onToggleMute: onToggleMute,
                                onVolumeChanged: onVolumeChanged,
                              ),
                              // 使用播放器自带的全屏路由，并同步桌面端的原生窗口状态。
                              IconButton(
                                tooltip:
                                    isFullscreen(context) ? '退出全屏' : '全屏',
                                color: Colors.white,
                                visualDensity: VisualDensity.compact,
                                onPressed:
                                    () => unawaited(toggleFullscreen(context)),
                                icon: Icon(
                                  isFullscreen(context)
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _VolumeControl extends StatefulWidget {
  final double volume;
  final bool muted;
  final bool compact;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolumeChanged;

  const _VolumeControl({
    required this.volume,
    required this.muted,
    required this.compact,
    required this.onToggleMute,
    required this.onVolumeChanged,
  });

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  final LayerLink _volumeLayerLink = LayerLink();
  final OverlayPortalController _overlayController =
      OverlayPortalController();
  Timer? _hideTimer;

  IconData get _volumeIcon {
    if (widget.muted || widget.volume <= 0) return Icons.volume_off_rounded;
    if (widget.volume < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  void _showVolumeSlider() {
    _hideTimer?.cancel();
    _overlayController.show();
  }

  void _scheduleHideVolumeSlider() {
    _hideTimer?.cancel();
    // 给鼠标从按钮移动到上方浮层预留少量时间，避免经过间隙时闪退。
    _hideTimer = Timer(const Duration(milliseconds: 160), () {
      if (mounted) _overlayController.hide();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final popupHeight = widget.compact ? 116.0 : 132.0;
    final volumeValue =
        (widget.muted ? 0.0 : widget.volume).clamp(0.0, 100.0).toDouble();
    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder:
          (context) => UnconstrainedBox(
            alignment: Alignment.topLeft,
            // Overlay 会下发全屏紧约束，先解除约束才能保持音量浮层的小尺寸。
            child: CompositedTransformFollower(
              link: _volumeLayerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topCenter,
              followerAnchor: Alignment.bottomCenter,
              offset: const Offset(0, -4),
              child: MouseRegion(
                onEnter: (_) => _showVolumeSlider(),
                onExit: (_) => _scheduleHideVolumeSlider(),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: 44,
                    height: popupHeight,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xEB111111),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: Colors.white12),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    // 旋转横向 Slider，使音量从下到上递增并保留原生拖动手感。
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2.5,
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 4.5,
                            elevation: 0,
                            pressedElevation: 0,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          value: volumeValue,
                          max: 100,
                          onChanged: widget.onVolumeChanged,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      child: CompositedTransformTarget(
        link: _volumeLayerLink,
        child: MouseRegion(
          onEnter: (_) => _showVolumeSlider(),
          onExit: (_) => _scheduleHideVolumeSlider(),
          child: Semantics(
            button: true,
            label: widget.muted ? '取消静音' : '静音',
            child: IconButton(
              color: Colors.white,
              visualDensity: VisualDensity.compact,
              onPressed: widget.onToggleMute,
              icon: Icon(_volumeIcon),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewTimelineBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final _ThumbnailPreviewController thumbnailController;

  const _PreviewTimelineBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.thumbnailController,
  });

  @override
  State<_PreviewTimelineBar> createState() => _PreviewTimelineBarState();
}

class _PreviewTimelineBarState extends State<_PreviewTimelineBar> {
  // 无涟漪的小尺寸滑块只需为圆点半径预留空间，使轨道接近铺满窗口。
  static const _sliderHorizontalInset = 4.5;

  bool _previewVisible = false;
  double _previewRatio = 0;
  int _activeFrameIndex = -1;
  Uint8List? _activeFrameBytes;
  late int _controllerRevision;

  // Web 与桌面端使用 hover，移动端继续由 Slider 的拖动回调触发预览。
  bool get _supportsHoverPreview {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  @override
  void initState() {
    super.initState();
    _controllerRevision = widget.thumbnailController.revision;
  }

  @override
  void didUpdateWidget(covariant _PreviewTimelineBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controllerRevision != widget.thumbnailController.revision) {
      _controllerRevision = widget.thumbnailController.revision;
      _previewVisible = false;
      _activeFrameIndex = -1;
      _activeFrameBytes = null;
    }
  }

  void _showPreview(double ratio) {
    if (!widget.thumbnailController.isAvailable ||
        widget.duration <= Duration.zero) {
      return;
    }

    final safeRatio = ratio.clamp(0.0, 1.0).toDouble();
    final previewPosition = Duration(
      milliseconds: (widget.duration.inMilliseconds * safeRatio).round(),
    );
    final preview = widget.thumbnailController.getThumbnailAt(previewPosition);
    if (preview == null) return;

    setState(() {
      _previewVisible = true;
      _previewRatio = safeRatio;
      _activeFrameIndex = preview.index;
      _activeFrameBytes = preview.imageBytes;
    });
  }

  void _hidePreview() {
    if (_previewVisible) setState(() => _previewVisible = false);
  }

  double _pointerRatio(double localX, double width) {
    final inset =
        width > _sliderHorizontalInset * 2 ? _sliderHorizontalInset : 0.0;
    final trackWidth = math.max(1.0, width - inset * 2);
    return ((localX - inset) / trackWidth).clamp(0.0, 1.0).toDouble();
  }

  double _previewLeft(double width, double previewWidth) {
    final inset =
        width > _sliderHorizontalInset * 2 ? _sliderHorizontalInset : 0.0;
    final trackWidth = math.max(0.0, width - inset * 2);
    final center = inset + trackWidth * _previewRatio;
    return (center - previewWidth / 2)
        .clamp(0.0, math.max(0.0, width - previewWidth))
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final max =
        widget.duration.inMilliseconds
            .toDouble()
            .clamp(1, double.infinity)
            .toDouble();
    final current =
        widget.position.inMilliseconds.toDouble().clamp(0, max).toDouble();
    return SizedBox(
      height: 34,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final previewWidth = math.min(220.0, width);
          final previewPosition = Duration(
            milliseconds:
                (widget.duration.inMilliseconds * _previewRatio).round(),
          );
          return MouseRegion(
            onHover:
                _supportsHoverPreview
                    ? (event) => _showPreview(
                      _pointerRatio(event.localPosition.dx, width),
                    )
                    : null,
            onExit: _supportsHoverPreview ? (_) => _hidePreview() : null,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    // 细轨道、小圆点和低对比未播放区，保持克制的桌面播放器观感。
                    trackHeight: 2.5,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white30,
                    disabledActiveTrackColor: Colors.white38,
                    disabledInactiveTrackColor: Colors.white12,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 4.5,
                      disabledThumbRadius: 0,
                      elevation: 0,
                      pressedElevation: 0,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: current,
                    max: max,
                    onChangeStart:
                        widget.duration > Duration.zero
                            ? (value) => _showPreview(value / max)
                            : null,
                    onChanged:
                        widget.duration > Duration.zero
                            ? (value) {
                              _showPreview(value / max);
                              widget.onSeek(
                                Duration(milliseconds: value.round()),
                              );
                            }
                            : null,
                    onChangeEnd:
                        widget.duration > Duration.zero
                            ? (_) => _hidePreview()
                            : null,
                  ),
                ),
                if (_previewVisible &&
                    _activeFrameBytes != null &&
                    previewWidth > 0)
                  Positioned(
                    left: _previewLeft(width, previewWidth),
                    bottom: 38,
                    child: IgnorePointer(
                      child: _ProgressPreview(
                        width: previewWidth,
                        imageBytes: _activeFrameBytes!,
                        timeText: _formatDuration(previewPosition),
                        frameIndex: _activeFrameIndex,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _ProgressPreview extends StatelessWidget {
  final double width;
  final Uint8List imageBytes;
  final String timeText;
  final int frameIndex;

  const _ProgressPreview({
    required this.width,
    required this.imageBytes,
    required this.timeText,
    required this.frameIndex,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    decoration: BoxDecoration(
      color: const Color(0xE6000000),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.white24),
      boxShadow: const [
        BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 8)),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Image.memory(
              imageBytes,
              key: ValueKey(frameIndex),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder:
                  (_, _, _) => const ColoredBox(
                    color: Color(0xFF111111),
                    child: Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white38,
                      ),
                    ),
                  ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
              child: Text(
                timeText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PlayerMessage extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PlayerMessage({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: Colors.white54, size: 48),
      const SizedBox(height: 12),
      Text(text, style: const TextStyle(color: Colors.white70)),
    ],
  );
}
