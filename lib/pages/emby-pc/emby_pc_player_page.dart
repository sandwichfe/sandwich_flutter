import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

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
  String _error = '';
  bool _playerReady = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _aspectRatio = 16 / 9;
  Timer? _progressTimer;
  _BifPreviewData? _previewData;

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
        setState(() => _previewData = previewData);
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
    _muted = !_muted;
    await _player.setVolume(_muted ? 0.0 : 100.0);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_playerReady) _reportProgress('/Sessions/Playing/Stopped');
    _progressTimer?.cancel();
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    _previewData = null;
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
      body: Center(
        child:
            _loading
                ? const CircularProgressIndicator()
                : _error.isNotEmpty
                ? _PlayerMessage(icon: Icons.error_outline, text: _error)
                : !_playerReady
                ? const _PlayerMessage(
                  icon: Icons.videocam_off_outlined,
                  text: '播放器不可用',
                )
                : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _aspectRatio,
                          child: Video(controller: _videoController),
                        ),
                      ),
                    ),
                    _PlayerControls(
                      player: _player,
                      position: _position,
                      duration: _duration,
                      isPlaying: _isPlaying,
                      previewData: _previewData,
                      muted: _muted,
                      onTogglePlay: _togglePlay,
                      onToggleMute: _toggleMute,
                    ),
                  ],
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

class _PlayerControls extends StatefulWidget {
  final Player player;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final _BifPreviewData? previewData;
  final bool muted;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleMute;

  const _PlayerControls({
    required this.player,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.previewData,
    required this.muted,
    required this.onTogglePlay,
    required this.onToggleMute,
  });

  @override
  State<_PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<_PlayerControls> {
  static const _sliderHorizontalInset = 24.0;

  bool _previewVisible = false;
  double _previewRatio = 0;
  int _activeFrameIndex = -1;
  Uint8List? _activeFrameBytes;

  @override
  void didUpdateWidget(covariant _PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previewData != widget.previewData) {
      _activeFrameIndex = -1;
      _activeFrameBytes = null;
      if (widget.previewData == null) _previewVisible = false;
    }
  }

  void _showPreview(double ratio) {
    final previewData = widget.previewData;
    final duration = widget.duration;
    if (previewData == null || duration <= Duration.zero) return;

    final safeRatio = ratio.clamp(0.0, 1.0).toDouble();
    final targetMs = (duration.inMilliseconds * safeRatio).round();
    final frameIndex = previewData.findFrameIndex(targetMs);
    // 同一缩略帧复用字节视图，避免播放器频繁刷新时重复解析图片。
    final frameBytes =
        frameIndex == _activeFrameIndex
            ? _activeFrameBytes
            : previewData.frameBytes(frameIndex);
    setState(() {
      _previewVisible = true;
      _previewRatio = safeRatio;
      _activeFrameIndex = frameIndex;
      _activeFrameBytes = frameBytes;
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
    final position = widget.position;
    final duration = widget.duration;
    final max =
        duration.inMilliseconds.toDouble().clamp(1, double.infinity).toDouble();
    final current = position.inMilliseconds.toDouble().clamp(0, max).toDouble();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: Row(
          children: [
            IconButton(
              tooltip: widget.isPlaying ? '暂停' : '播放',
              color: Colors.white,
              onPressed: widget.onTogglePlay,
              icon: Icon(
                widget.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final previewWidth = math.min(240.0, width);
                  final previewPosition = Duration(
                    milliseconds:
                        (duration.inMilliseconds * _previewRatio).round(),
                  );
                  return MouseRegion(
                    onHover:
                        (event) => _showPreview(
                          _pointerRatio(event.localPosition.dx, width),
                        ),
                    onExit: (_) => _hidePreview(),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Slider(
                          value: current,
                          max: max,
                          onChangeStart: (value) => _showPreview(value / max),
                          onChanged: (value) {
                            _showPreview(value / max);
                            unawaited(
                              widget.player.seek(
                                Duration(milliseconds: value.round()),
                              ),
                            );
                          },
                          onChangeEnd: (_) => _hidePreview(),
                        ),
                        if (_previewVisible &&
                            _activeFrameBytes != null &&
                            previewWidth > 0)
                          Positioned(
                            left: _previewLeft(width, previewWidth),
                            bottom: 52,
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
            ),
            Text(
              '${_formatDuration(position)} / ${_formatDuration(duration)}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: widget.muted ? '取消静音' : '静音',
              color: Colors.white,
              onPressed: widget.onToggleMute,
              icon: Icon(
                widget.muted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
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
