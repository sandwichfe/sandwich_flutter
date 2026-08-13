import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'emby_pc_models.dart';
import 'emby_pc_service.dart';

// Android 播放器只调整当前应用窗口亮度，退出播放器后恢复跟随系统亮度。
class _AndroidWindowBrightness {
  static const MethodChannel _channel = MethodChannel(
    'helloworld_flutter/player_brightness',
  );

  static Future<double> getBrightness() async {
    try {
      final brightness = await _channel.invokeMethod<double>('getBrightness');
      return (brightness ?? 0.5).clamp(0.01, 1.0).toDouble();
    } on PlatformException catch (error) {
      debugPrint('读取 Android 窗口亮度失败：$error');
      return 0.5;
    } on MissingPluginException catch (error) {
      debugPrint('Android 窗口亮度通道不可用：$error');
      return 0.5;
    }
  }

  static Future<void> setBrightness(double brightness) async {
    try {
      await _channel.invokeMethod<void>('setBrightness', {
        'brightness': brightness.clamp(0.01, 1.0).toDouble(),
      });
    } on PlatformException catch (error) {
      debugPrint('设置 Android 窗口亮度失败：$error');
    } on MissingPluginException catch (error) {
      debugPrint('Android 窗口亮度通道不可用：$error');
    }
  }

  static Future<void> resetBrightness() async {
    try {
      await _channel.invokeMethod<void>('resetBrightness');
    } on PlatformException catch (error) {
      debugPrint('恢复 Android 系统亮度失败：$error');
    } on MissingPluginException catch (error) {
      debugPrint('Android 窗口亮度通道不可用：$error');
    }
  }
}

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

class _EmbyPcPlayerPageState extends State<EmbyPcPlayerPage>
    with WindowListener {
  static const double _defaultVolume = 5.0;
  // 只在当前应用进程内保存音量；应用重启后静态值会重新回到默认音量。
  static double _sessionVolume = _defaultVolume;
  static double _sessionVolumeBeforeMute = _defaultVolume;

  late final Player _player;
  late final VideoController _videoController;
  late final String _playSessionId;
  late final String _mediaSourceId;
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  bool _loading = true;
  bool _buffering = false;
  bool _muted = _sessionVolume <= 0;
  double _volume = _sessionVolume;
  double _volumeBeforeMute = _sessionVolumeBeforeMute;
  double? _networkSpeedBytesPerSecond;
  String _error = '';
  bool _playerReady = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _aspectRatio = 16 / 9;
  Timer? _progressTimer;
  Future<void> _playbackReportQueue = Future<void>.value();
  bool _closing = false;
  bool _windowClosing = false;
  bool _allowPop = false;
  bool _stopReportQueued = false;
  late final _ThumbnailPreviewController _thumbnailPreviewController;
  // 保持音量控件状态引用稳定，让键盘调节也能唤起同一个音量浮层。
  final GlobalKey<_VolumeControlState> _volumeControlKey =
      GlobalKey<_VolumeControlState>();

  @override
  void initState() {
    super.initState();
    // 每次进入播放器创建独立会话，三类上报都复用该标识。
    _playSessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${widget.item.id}';
    // 详情数据优先使用真实媒体源，工作台精简条目则回退到媒体条目 ID。
    _mediaSourceId = widget.item.mediaSources
        .map((source) => source.id)
        .firstWhere((id) => id.isNotEmpty, orElse: () => widget.item.id);
    // Use Emby's known dimensions while the native decoder is still loading.
    if (widget.item.width != null &&
        widget.item.height != null &&
        widget.item.height! > 0) {
      _aspectRatio = widget.item.width! / widget.item.height!;
    }
    _player = Player();
    _videoController = VideoController(_player);
    if (_usesWindowCloseGuard) {
      // Windows 关闭窗口时先保留进程，等待本次播放会话完成停止上报。
      windowManager.addListener(this);
      unawaited(_setWindowCloseGuard(true));
    }
    // 缩略图数据与控制层状态分离，后续可在这里接入其他 Emby 预览来源。
    _thumbnailPreviewController = _ThumbnailPreviewController();
    _listenToPlayerState();
    _initializePlayer();
  }

  bool get _usesWindowCloseGuard =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  Future<void> _setWindowCloseGuard(bool enabled) async {
    try {
      await windowManager.setPreventClose(enabled);
    } catch (error, stackTrace) {
      // 窗口插件异常不能阻断播放器，但需要保留日志说明关闭保护未生效。
      debugPrint('Windows 播放器关闭保护设置失败：$error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  void onWindowClose() {
    unawaited(_closeWindowAfterPlaybackReport());
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
      _player.stream.buffering.listen((buffering) {
        if (mounted) setState(() => _buffering = buffering);
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

  Future<void> _observeNetworkSpeed() async {
    if (kIsWeb) return;

    try {
      // mpv 的原始输入速率单位为字节/秒，可直接反映当前视频流下载速度。
      await (_player.platform as dynamic).observeProperty(
        'demuxer-cache-state',
        (String value) async {
          if (!mounted || value.isEmpty) return;
          try {
            final cacheState = jsonDecode(value);
            if (cacheState is! Map<String, dynamic>) return;
            final rawInputRate = cacheState['raw-input-rate'];
            if (rawInputRate is! num) return;

            final speed = math.max(0.0, rawInputRate.toDouble());
            if (_networkSpeedBytesPerSecond == speed) return;
            if (_loading || _buffering) {
              setState(() => _networkSpeedBytesPerSecond = speed);
            } else {
              _networkSpeedBytesPerSecond = speed;
            }
          } catch (_) {
            // 缓存属性短暂不可解析时保留上一次速率，不影响视频播放。
          }
        },
      );
    } catch (_) {
      // 非 mpv 平台不提供该属性时仅隐藏具体速率，保留加载状态提示。
    }
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
      // 在打开媒体前同步本次运行期间的音量，避免切换视频时重置或短暂满音量。
      await _player.setVolume(_sessionVolume);
      await _observeNetworkSpeed();
      await _player.open(media);
      if (!mounted) {
        await _player.dispose();
        return;
      }
      if (_error.isNotEmpty) return;
      _progressTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _reportPlayback(EmbyPcPlaybackEvent.progress),
      );
      unawaited(_reportPlayback(EmbyPcPlaybackEvent.started));
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

  // 串行发送播放事件，确保最终进度一定排在停止事件之前到达服务端。
  Future<void> _reportPlayback(
    EmbyPcPlaybackEvent event, {
    String progressEventName = 'TimeUpdate',
  }) {
    final ticks = _player.state.position.inMicroseconds * 10;
    final paused = !_player.state.playing;
    final muted = _muted;
    final volumeLevel = _volume.round().clamp(0, 100).toInt();
    final report = _playbackReportQueue.then(
      (_) => EmbyPcService.instance.reportPlayback(
        itemId: widget.item.id,
        mediaSourceId: _mediaSourceId,
        playSessionId: _playSessionId,
        event: event,
        positionTicks: ticks,
        paused: paused,
        muted: muted,
        volumeLevel: volumeLevel,
        canSeek: _duration > Duration.zero || widget.item.runTimeTicks > 0,
        progressEventName: progressEventName,
      ),
    );
    // 上报失败不打断本地播放，但必须保留状态码或网络异常供诊断。
    _playbackReportQueue = report.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Emby 播放状态上报失败：$error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
    return _playbackReportQueue;
  }

  Future<void> _togglePlay() async {
    if (!_playerReady) return;
    _isPlaying ? await _player.pause() : await _player.play();
    unawaited(
      _reportPlayback(
        EmbyPcPlaybackEvent.progress,
        progressEventName: _player.state.playing ? 'Unpause' : 'Pause',
      ),
    );
  }

  // 正常返回前等待最后进度和停止事件完成，短时间播放也不再依赖 dispose 异步兜底。
  Future<void> _closePlayer() async {
    if (_closing) return;
    setState(() => _closing = true);
    await _finishPlaybackReports();
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop(true);
  }

  // 关闭整个窗口时同样等待最终上报，再解除窗口保护并销毁桌面窗口。
  Future<void> _closeWindowAfterPlaybackReport() async {
    if (_windowClosing) return;
    _windowClosing = true;
    if (mounted && !_closing) setState(() => _closing = true);
    await _finishPlaybackReports();
    await _setWindowCloseGuard(false);
    await windowManager.destroy();
  }

  Future<void> _finishPlaybackReports() async {
    _progressTimer?.cancel();
    if (!_playerReady || _stopReportQueued) {
      await _playbackReportQueue;
      return;
    }
    _stopReportQueued = true;
    await _reportPlayback(EmbyPcPlaybackEvent.progress);
    await _reportPlayback(EmbyPcPlaybackEvent.stopped);
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
    // 静音状态和最近一次非零音量都在后续视频中继续复用。
    _sessionVolume = targetVolume;
    _sessionVolumeBeforeMute = _volumeBeforeMute;
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
    // 仅记录用户主动设置的音量，不把播放器初始化期间的临时状态写入会话值。
    _sessionVolume = safeVolume;
    if (safeVolume > 0) _sessionVolumeBeforeMute = safeVolume;
    await _player.setVolume(safeVolume);
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // 播放器离开后不保留窗口级亮度覆盖，重新跟随 Android 系统设置。
      unawaited(_AndroidWindowBrightness.resetBrightness());
    }
    // 非正常移除页面时仍排入停止事件；正常返回路径已在 _closePlayer 中等待完成。
    if (_playerReady && !_stopReportQueued) {
      _stopReportQueued = true;
      unawaited(_reportPlayback(EmbyPcPlaybackEvent.stopped));
    }
    if (_usesWindowCloseGuard) {
      windowManager.removeListener(this);
      unawaited(_setWindowCloseGuard(false));
    }
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    _thumbnailPreviewController.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: _allowPop,
      // 系统返回、键盘返回和标题栏返回都先经过同一个可等待退出流程。
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_closePlayer());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: BackButton(
            onPressed: _closing ? null : () => unawaited(_closePlayer()),
          ),
          title: Text(widget.item.name, overflow: TextOverflow.ellipsis),
          // 退出上报期间提供明确状态，并禁用重复返回操作。
          actions: [
            if (_closing)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
        body:
          _loading
              ? Center(
                child: _PlayerLoadingIndicator(
                  statusText: '正在加载',
                  networkSpeedBytesPerSecond: _networkSpeedBytesPerSecond,
                ),
              )
              : _error.isNotEmpty
              ? Center(
                child: _PlayerMessage(icon: Icons.error_outline, text: _error),
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
                        buffering: _buffering,
                        networkSpeedBytesPerSecond:
                            _networkSpeedBytesPerSecond,
                        thumbnailPreviewController: _thumbnailPreviewController,
                        muted: _muted,
                        volume: _volume,
                        volumeControlKey: _volumeControlKey,
                        onTogglePlay: _togglePlay,
                        onToggleMute: _toggleMute,
                        onVolumeChanged:
                            (value) => unawaited(_setVolume(value)),
                      ),
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

  const _ThumbnailPreviewFrame({required this.index, required this.imageBytes});
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
  // 方向键使用播放器中常见的 5 秒步长，避免 10 秒跳转过于突兀。
  static const _keyboardSeekStep = Duration(seconds: 5);
  static const _keyboardRewindStep = Duration(seconds: -5);
  // 每次方向键调整 5 个音量单位，与桌面端音量操作保持一致。
  static const _keyboardVolumeStep = 5.0;

  final Player player;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool buffering;
  final double? networkSpeedBytesPerSecond;
  final _ThumbnailPreviewController thumbnailPreviewController;
  final bool muted;
  final double volume;
  final GlobalKey<_VolumeControlState> volumeControlKey;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolumeChanged;

  const _PlayerControls({
    required this.player,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.buffering,
    required this.networkSpeedBytesPerSecond,
    required this.thumbnailPreviewController,
    required this.muted,
    required this.volume,
    required this.volumeControlKey,
    required this.onTogglePlay,
    required this.onToggleMute,
    required this.onVolumeChanged,
  });

  Future<void> _toggleFullscreen(BuildContext context) async {
    // Flutter Tooltip 使用 OverlayPortal；等待退出动画结束后再改变窗口尺寸。
    final tooltipWasVisible = Tooltip.dismissAllToolTips();
    if (tooltipWasVisible) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await WidgetsBinding.instance.endOfFrame;
    }
    if (context.mounted) await toggleFullscreen(context);
  }

  void _seekBy(Duration delta) {
    final currentPosition = player.state.position;
    final mediaDuration = player.state.duration;
    var targetPosition = currentPosition + delta;
    if (targetPosition < Duration.zero) {
      targetPosition = Duration.zero;
    } else if (mediaDuration > Duration.zero &&
        targetPosition > mediaDuration) {
      targetPosition = mediaDuration;
    }
    unawaited(player.seek(targetPosition));
  }

  void _adjustVolume(double delta) {
    // 通过页面回调修改音量，确保键盘、滑块和静音状态使用同一份状态。
    final targetVolume = (volume + delta)
        .clamp(0.0, 100.0)
        .toDouble();
    onVolumeChanged(targetVolume);
    // 键盘调节后显示现有音量条，连续按键时由音量控件重新计算隐藏时间。
    volumeControlKey.currentState?.showForKeyboardAdjustment();
  }

  bool get _usesAndroidTouchGestures =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final playbackStateIndicator = Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: isPlaying || buffering
            ? const SizedBox.shrink(key: ValueKey('playing'))
            : Container(
                key: const ValueKey('paused'),
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  // 半透明白色按钮兼顾不同亮度视频画面的可读性。
                  color: const Color(0x2EFFFFFF),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xB3FFFFFF)),
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
    );

    return CallbackShortcuts(
      bindings: {
        // 自定义控制层接管默认控制层的方向键交互。
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seekBy(_keyboardRewindStep),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _seekBy(_keyboardSeekStep),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _adjustVolume(_keyboardVolumeStep),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _adjustVolume(-_keyboardVolumeStep),
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 点击视频画面切换播放状态；底部控制栏位于该层上方，仍可独立响应操作。
            Positioned.fill(
              child: Semantics(
                button: true,
                label: isPlaying ? '暂停' : '播放',
                child: _usesAndroidTouchGestures
                    ? _AndroidPlayerGestureLayer(
                        player: player,
                        volume: volume,
                        onTap: onTogglePlay,
                        onVolumeChanged: onVolumeChanged,
                        child: playbackStateIndicator,
                      )
                    : MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onTogglePlay,
                          child: playbackStateIndicator,
                        ),
                      ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  // 两种状态的组件类型已经不同；不使用固定 Key，避免缓冲状态快速反复时
                  // 新旧动画子项在 AnimatedSwitcher 的 Stack 中产生重复 Key。
                  child: buffering
                      ? Center(
                          child: _PlayerLoadingIndicator(
                            statusText: '正在缓冲',
                            networkSpeedBytesPerSecond:
                                networkSpeedBytesPerSecond,
                          ),
                        )
                      : const SizedBox.shrink(),
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
                    final timeText = constraints.maxWidth < 380
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
                                    key: volumeControlKey,
                                    volume: volume,
                                    muted: muted,
                                    compact: compact,
                                    onToggleMute: onToggleMute,
                                    onVolumeChanged: onVolumeChanged,
                                  ),
                                  // 使用播放器自带的全屏路由，并同步桌面端的原生窗口状态。
                                  IconButton(
                                    tooltip: isFullscreen(context)
                                        ? '退出全屏'
                                        : '全屏',
                                    color: Colors.white,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        unawaited(_toggleFullscreen(context)),
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

enum _AndroidPlayerGestureMode {
  pending,
  seek,
  brightness,
  volume,
}

class _AndroidPlayerGestureLayer extends StatefulWidget {
  final Player player;
  final double volume;
  final VoidCallback onTap;
  final ValueChanged<double> onVolumeChanged;
  final Widget child;

  const _AndroidPlayerGestureLayer({
    required this.player,
    required this.volume,
    required this.onTap,
    required this.onVolumeChanged,
    required this.child,
  });

  @override
  State<_AndroidPlayerGestureLayer> createState() =>
      _AndroidPlayerGestureLayerState();
}

class _AndroidPlayerGestureLayerState
    extends State<_AndroidPlayerGestureLayer> {
  static const double _directionLockDistance = 10;
  static const Duration _maximumSeekRange = Duration(minutes: 5);

  _AndroidPlayerGestureMode? _mode;
  Offset _dragOffset = Offset.zero;
  bool _startedOnLeft = false;
  double _brightness = 0.5;
  double _startBrightness = 0.5;
  double _startVolume = 0;
  double _displayValue = 0;
  Duration _startPosition = Duration.zero;
  Duration _seekPosition = Duration.zero;
  Timer? _feedbackTimer;
  bool _feedbackVisible = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBrightness());
  }

  Future<void> _loadBrightness() async {
    final brightness = await _AndroidWindowBrightness.getBrightness();
    if (!mounted) return;
    _brightness = brightness;
  }

  void _handlePanStart(DragStartDetails details) {
    final width = context.size?.width ?? 0;
    _feedbackTimer?.cancel();
    _mode = _AndroidPlayerGestureMode.pending;
    _dragOffset = Offset.zero;
    _startedOnLeft = details.localPosition.dx < width / 2;
    _startBrightness = _brightness;
    _startVolume = widget.volume;
    _displayValue = _startedOnLeft ? _startBrightness * 100 : _startVolume;
    _startPosition = widget.player.state.position;
    _seekPosition = _startPosition;
    _feedbackVisible = false;
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    final size = context.size;
    if (size == null || size.width <= 0 || size.height <= 0) return;

    _dragOffset += details.delta;
    if (_mode == _AndroidPlayerGestureMode.pending) {
      final horizontalDistance = _dragOffset.dx.abs();
      final verticalDistance = _dragOffset.dy.abs();
      if (math.max(horizontalDistance, verticalDistance) <
          _directionLockDistance) {
        return;
      }
      _mode = horizontalDistance >= verticalDistance
          ? _AndroidPlayerGestureMode.seek
          : (_startedOnLeft
                ? _AndroidPlayerGestureMode.brightness
                : _AndroidPlayerGestureMode.volume);
    }

    switch (_mode!) {
      case _AndroidPlayerGestureMode.seek:
        _updateSeek(size.width);
        break;
      case _AndroidPlayerGestureMode.brightness:
        _updateBrightness(size.height);
        break;
      case _AndroidPlayerGestureMode.volume:
        _updateVolume(size.height);
        break;
      case _AndroidPlayerGestureMode.pending:
        return;
    }
  }

  void _updateSeek(double width) {
    final duration = widget.player.state.duration;
    if (duration <= Duration.zero) return;
    // 横跨整个屏幕最多调整五分钟，长视频也能保持可控的拖动精度。
    final seekRange = duration < _maximumSeekRange
        ? duration
        : _maximumSeekRange;
    final deltaMilliseconds =
        seekRange.inMilliseconds * _dragOffset.dx / width;
    final targetMilliseconds = (_startPosition.inMilliseconds +
            deltaMilliseconds.round())
        .clamp(0, duration.inMilliseconds)
        .toInt();
    setState(() {
      _seekPosition = Duration(milliseconds: targetMilliseconds);
      _feedbackVisible = true;
    });
  }

  void _updateBrightness(double height) {
    final brightness = (_startBrightness - _dragOffset.dy / height)
        .clamp(0.01, 1.0)
        .toDouble();
    if ((brightness - _brightness).abs() < 0.005) return;
    setState(() {
      _brightness = brightness;
      _displayValue = brightness * 100;
      _feedbackVisible = true;
    });
    unawaited(_AndroidWindowBrightness.setBrightness(brightness));
  }

  void _updateVolume(double height) {
    final volume = (_startVolume - _dragOffset.dy / height * 100)
        .clamp(0.0, 100.0)
        .toDouble();
    if ((volume - _displayValue).abs() < 0.5 && _feedbackVisible) return;
    setState(() {
      _displayValue = volume;
      _feedbackVisible = true;
    });
    widget.onVolumeChanged(volume);
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_mode == _AndroidPlayerGestureMode.seek && _feedbackVisible) {
      unawaited(widget.player.seek(_seekPosition));
    }
    _scheduleFeedbackHide();
  }

  void _handlePanCancel() {
    _scheduleFeedbackHide();
  }

  void _scheduleFeedbackHide() {
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _feedbackVisible = false);
    });
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onPanStart: _handlePanStart,
      onPanUpdate: _handlePanUpdate,
      onPanEnd: _handlePanEnd,
      onPanCancel: _handlePanCancel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _feedbackVisible ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Center(child: _buildFeedback()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedback() {
    final mode = _mode;
    final IconData icon;
    final String text;
    switch (mode) {
      case _AndroidPlayerGestureMode.seek:
        icon = _seekPosition >= _startPosition
            ? Icons.fast_forward_rounded
            : Icons.fast_rewind_rounded;
        text = '${_formatDuration(_seekPosition)} / '
            '${_formatDuration(widget.player.state.duration)}';
        break;
      case _AndroidPlayerGestureMode.brightness:
        icon = Icons.brightness_6_rounded;
        text = '${_displayValue.round()}%';
        break;
      case _AndroidPlayerGestureMode.volume:
        icon = _displayValue <= 0
            ? Icons.volume_off_rounded
            : Icons.volume_up_rounded;
        text = '${_displayValue.round()}%';
        break;
      case _AndroidPlayerGestureMode.pending:
      case null:
        icon = Icons.touch_app_rounded;
        text = '';
        break;
    }

    return Container(
      constraints: const BoxConstraints(minWidth: 116, minHeight: 88),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 32),
          const SizedBox(height: 8),
          Text(
            text,
            maxLines: 1,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
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

class _PlayerLoadingIndicator extends StatelessWidget {
  final String statusText;
  final double? networkSpeedBytesPerSecond;

  const _PlayerLoadingIndicator({
    required this.statusText,
    required this.networkSpeedBytesPerSecond,
  });

  @override
  Widget build(BuildContext context) {
    final speedText = _formatNetworkSpeed(networkSpeedBytesPerSecond);
    return Semantics(
      container: true,
      liveRegion: true,
      label: '$statusText，当前网速 $speedText',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xA6000000),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white12),
              ),
              child: Text(
                '$statusText  ·  $speedText',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 使用二进制进位并控制小数位，兼顾低速可读性与高速数值稳定性。
  String _formatNetworkSpeed(double? bytesPerSecond) {
    if (bytesPerSecond == null) return '-- KB/s';
    if (bytesPerSecond <= 0) return '0 KB/s';

    const kilobyte = 1024.0;
    const megabyte = kilobyte * 1024;
    const gigabyte = megabyte * 1024;
    if (bytesPerSecond >= gigabyte) {
      return '${(bytesPerSecond / gigabyte).toStringAsFixed(1)} GB/s';
    }
    if (bytesPerSecond >= megabyte) {
      final speed = bytesPerSecond / megabyte;
      return '${speed.toStringAsFixed(speed < 10 ? 1 : 0)} MB/s';
    }
    final speed = bytesPerSecond / kilobyte;
    return '${speed.toStringAsFixed(speed < 10 ? 1 : 0)} KB/s';
  }
}

class _VolumeControl extends StatefulWidget {
  final double volume;
  final bool muted;
  final bool compact;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolumeChanged;

  const _VolumeControl({
    super.key,
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
  OverlayEntry? _volumeOverlayEntry;
  Timer? _hideTimer;
  bool _overlayRefreshScheduled = false;
  bool _pointerInsideVolumeArea = false;

  IconData get _volumeIcon {
    if (widget.muted || widget.volume <= 0) return Icons.volume_off_rounded;
    if (widget.volume < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  void _showVolumeSlider() {
    _hideTimer?.cancel();
    if (_volumeOverlayEntry != null) return;

    // 使用普通 OverlayEntry 避免全屏切换期间 OverlayPortal 缓存旧窗口尺寸。
    final entry = OverlayEntry(builder: _buildVolumeOverlay);
    _volumeOverlayEntry = entry;
    Overlay.of(context).insert(entry);
  }

  void showForKeyboardAdjustment() {
    _showVolumeSlider();
    _hideTimer?.cancel();
    // 连续按上下键时重新计时，最后一次操作后为用户保留足够的读数时间。
    _hideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted && !_pointerInsideVolumeArea) _hideVolumeSlider();
    });
  }

  void _handlePointerEnter() {
    _pointerInsideVolumeArea = true;
    _showVolumeSlider();
  }

  void _handlePointerExit() {
    _pointerInsideVolumeArea = false;
    _scheduleHideVolumeSlider();
  }

  void _scheduleHideVolumeSlider() {
    _hideTimer?.cancel();
    // 给鼠标从按钮移动到上方浮层预留少量时间，避免经过间隙时闪退。
    _hideTimer = Timer(const Duration(milliseconds: 160), () {
      if (mounted) _hideVolumeSlider();
    });
  }

  void _hideVolumeSlider() {
    final entry = _volumeOverlayEntry;
    if (entry == null) return;
    _volumeOverlayEntry = null;
    entry.remove();
    entry.dispose();
  }

  void _scheduleVolumeOverlayRefresh() {
    if (_overlayRefreshScheduled || _volumeOverlayEntry == null) return;
    _overlayRefreshScheduled = true;
    // didUpdateWidget 位于 build 阶段，延迟刷新可避免此时直接标记 Overlay 为脏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayRefreshScheduled = false;
      final entry = _volumeOverlayEntry;
      if (!mounted || entry == null) return;
      entry.markNeedsBuild();
    });
  }

  @override
  void didUpdateWidget(covariant _VolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 音量或紧凑布局变化时，同步刷新独立 Overlay 中的滑条内容。
    _scheduleVolumeOverlayRefresh();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hideVolumeSlider();
    super.dispose();
  }

  Widget _buildVolumeOverlay(BuildContext context) {
    final popupHeight = widget.compact ? 116.0 : 132.0;
    final volumeValue =
        (widget.muted ? 0.0 : widget.volume).clamp(0.0, 100.0).toDouble();
    return UnconstrainedBox(
      alignment: Alignment.topLeft,
      // 解除 Overlay 的全屏紧约束，让音量浮层保持自身尺寸。
      child: CompositedTransformFollower(
        link: _volumeLayerLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -4),
        child: MouseRegion(
          onEnter: (_) => _handlePointerEnter(),
          onExit: (_) => _handlePointerExit(),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _volumeLayerLink,
      child: MouseRegion(
        onEnter: (_) => _handlePointerEnter(),
        onExit: (_) => _handlePointerExit(),
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
