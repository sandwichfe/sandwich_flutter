import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../models/emby_models.dart';
import '../../services/emby_service.dart';

enum _PlaybackOrientation { portrait, landscape }

typedef _SeekRequestCallback =
    Future<void> Function(Duration target, {bool resumePlayback});

class EmbyStreamPage extends StatefulWidget {
  final List<EmbyItem> items;
  final int initialIndex;
  const EmbyStreamPage({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  @override
  State<EmbyStreamPage> createState() => _EmbyStreamPageState();
}

class _EmbyStreamPageState extends State<EmbyStreamPage>
    with SingleTickerProviderStateMixin {
  static const double _switchVelocity = 600;
  static const double _seekSwipeDurationPercent = 0.08;
  static const double _seekSwipeMinDistance = 18;
  static const Duration _settleDuration = Duration(milliseconds: 180);
  static const Duration _switchExitDuration = Duration(milliseconds: 320);
  static const Duration _seekTimeout = Duration(seconds: 8);
  static const Duration _endSeekSafetyMargin = Duration(seconds: 1);

  late int _index;
  late List<EmbyItem> _items;
  late final AnimationController _slideController;
  VideoPlayerController? _ctrl;
  bool _showControls = false;
  bool _isSwitchingVideo = false;
  double _rawDragOffsetY = 0;
  double _dragOffsetY = 0;
  double _rawDragOffsetX = 0;
  Duration _seekDragStartPosition = Duration.zero;
  int _playRequestId = 0;
  int _seekFeedbackId = 0;
  int? _seekFeedbackSeconds;
  Duration? _seekFeedbackTarget;
  bool _showSeekFeedback = false;
  bool _isSeekScrubbing = false;
  bool _isApplyingSeek = false;
  bool _isFullscreen = false;
  bool _isPlaying = false;
  bool? _desiredPlaying;
  bool _isApplyingPlayState = false;
  _PlaybackOrientation _playbackOrientation = _PlaybackOrientation.portrait;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _items = List.of(widget.items);
    _slideController = AnimationController(
      vsync: this,
      duration: _settleDuration,
    );
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _play(_index);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _slideController.dispose();
    _ctrl?.removeListener(_handlePlaybackControllerChanged);
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _play(int index) async {
    final requestId = ++_playRequestId;
    final oldCtrl = _ctrl;
    if (oldCtrl != null) {
      oldCtrl.removeListener(_handlePlaybackControllerChanged);
      if (mounted) {
        setState(() {
          _ctrl = null;
          _isPlaying = false;
          _desiredPlaying = null;
        });
        await WidgetsBinding.instance.endOfFrame;
      } else {
        _ctrl = null;
      }
      await oldCtrl.dispose();
    }

    final url = EmbyService().getStreamUrl(_items[index].id);
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    await ctrl.initialize();
    if (!mounted || requestId != _playRequestId) {
      await ctrl.dispose();
      return;
    }
    if (_isFullscreen) {
      await _applyPlaybackOrientation(
        _orientationForVideoSize(ctrl.value.size),
      );
      if (!mounted || requestId != _playRequestId) {
        await ctrl.dispose();
        return;
      }
    }
    ctrl.addListener(_handlePlaybackControllerChanged);
    setState(() {
      _ctrl = ctrl;
      _isPlaying = true;
      _desiredPlaying = null;
    });
    await ctrl.play();
    if (!mounted || requestId != _playRequestId || _ctrl != ctrl) return;
    setState(() => _isPlaying = ctrl.value.isPlaying);
  }

  void _handlePlaybackControllerChanged() {
    final ctrl = _ctrl;
    if (!mounted ||
        ctrl == null ||
        !ctrl.value.isInitialized ||
        _desiredPlaying != null) {
      return;
    }

    final nextPlaying = ctrl.value.isPlaying;
    if (_isPlaying != nextPlaying) {
      setState(() => _isPlaying = nextPlaying);
    }
  }

  _PlaybackOrientation _orientationForVideoSize(Size size) {
    if (size.width > 0 && size.width > size.height) {
      return _PlaybackOrientation.landscape;
    }
    return _PlaybackOrientation.portrait;
  }

  Future<void> _applyPlaybackOrientation(
    _PlaybackOrientation orientation,
  ) async {
    final orientations =
        orientation == _PlaybackOrientation.landscape
            ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
            : const [DeviceOrientation.portraitUp];

    await SystemChrome.setPreferredOrientations(orientations);
    if (!mounted) return;
    setState(() => _playbackOrientation = orientation);
  }

  Future<void> _togglePlaybackOrientation() {
    final next =
        _playbackOrientation == _PlaybackOrientation.landscape
            ? _PlaybackOrientation.portrait
            : _PlaybackOrientation.landscape;
    return _applyPlaybackOrientation(next);
  }

  Future<void> _enterFullscreen() async {
    setState(() => _isFullscreen = true);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final ctrl = _ctrl;
    final orientation =
        ctrl != null && ctrl.value.isInitialized
            ? _orientationForVideoSize(ctrl.value.size)
            : _PlaybackOrientation.portrait;
    await _applyPlaybackOrientation(orientation);
  }

  Future<void> _exitFullscreen() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!mounted) return;
    setState(() {
      _isFullscreen = false;
      _playbackOrientation = _PlaybackOrientation.portrait;
    });
  }

  Future<void> _handleBackPressed() async {
    if (_isFullscreen ||
        _playbackOrientation == _PlaybackOrientation.landscape) {
      await _exitFullscreen();
      return;
    }

    if (!mounted) return;
    Navigator.pop(context, _items);
  }

  double _visualDragOffset(double rawOffset) {
    if ((_index == 0 && rawOffset > 0) ||
        (_index == _items.length - 1 && rawOffset < 0)) {
      return rawOffset * 0.28;
    }
    return rawOffset;
  }

  Future<void> _animateDragTo(
    double target, {
    Curve curve = Curves.easeOutCubic,
    Duration? duration,
  }) async {
    _slideController.stop();
    _slideController.duration = duration ?? _settleDuration;
    final animation = Tween<double>(
      begin: _dragOffsetY,
      end: target,
    ).animate(CurvedAnimation(parent: _slideController, curve: curve));

    void updateOffset() {
      if (mounted) setState(() => _dragOffsetY = animation.value);
    }

    animation.addListener(updateOffset);
    _slideController.reset();
    try {
      await _slideController.forward();
    } on TickerCanceled {
      // A new drag or page dispose can intentionally cancel the in-flight slide.
    } finally {
      animation.removeListener(updateOffset);
    }
  }

  Future<void> _switchTo(int targetIndex, {double? exitOffset}) async {
    if (_isSwitchingVideo ||
        targetIndex == _index ||
        targetIndex < 0 ||
        targetIndex >= _items.length) {
      return;
    }

    setState(() => _isSwitchingVideo = true);
    if (exitOffset != null) {
      await _animateDragTo(
        exitOffset,
        duration: _switchExitDuration,
        curve: Curves.easeInOutCubic,
      );
    }
    if (!mounted) return;

    setState(() {
      _index = targetIndex;
      _rawDragOffsetY = 0;
      _dragOffsetY = 0;
    });
    await _play(targetIndex);
    if (mounted) setState(() => _isSwitchingVideo = false);
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    if (_isSwitchingVideo) return;
    _slideController.stop();
    _rawDragOffsetY = 0;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_isSwitchingVideo) return;
    setState(() {
      _rawDragOffsetY += details.delta.dy;
      _dragOffsetY = _visualDragOffset(_rawDragOffsetY);
    });
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (_isSwitchingVideo) return;

    final height = MediaQuery.sizeOf(context).height;
    final velocity = details.primaryVelocity ?? 0;
    final distanceThreshold = height * 0.16;
    final shouldNext =
        _index < _items.length - 1 &&
        (_rawDragOffsetY < -distanceThreshold || velocity < -_switchVelocity);
    final shouldPrev =
        _index > 0 &&
        (_rawDragOffsetY > distanceThreshold || velocity > _switchVelocity);

    if (shouldNext) {
      _switchTo(_index + 1, exitOffset: -height);
    } else if (shouldPrev) {
      _switchTo(_index - 1, exitOffset: height);
    } else {
      _rawDragOffsetY = 0;
      _animateDragTo(0);
    }
  }

  void _handleVerticalDragCancel() {
    if (_isSwitchingVideo) return;
    _rawDragOffsetY = 0;
    _animateDragTo(0);
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    final ctrl = _ctrl;
    if (_isApplyingSeek || ctrl == null || !ctrl.value.isInitialized) return;
    _rawDragOffsetX = 0;
    _seekDragStartPosition = ctrl.value.position;
    setState(() {
      _seekFeedbackSeconds = 0;
      _seekFeedbackTarget = _seekDragStartPosition;
      _showSeekFeedback = true;
      _isSeekScrubbing = true;
    });
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    final ctrl = _ctrl;
    if (_isApplyingSeek || ctrl == null || !ctrl.value.isInitialized) return;
    _rawDragOffsetX += details.delta.dx;
    final seconds = _seekSwipeSecondsForOffset(_rawDragOffsetX);
    final target = _clampPosition(
      _seekDragStartPosition + Duration(seconds: seconds),
      ctrl.value.duration,
    );
    setState(() {
      _seekFeedbackSeconds = seconds;
      _seekFeedbackTarget = target;
      _showSeekFeedback = true;
      _isSeekScrubbing = true;
    });
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (_isApplyingSeek) return;
    final ctrl = _ctrl;
    if (ctrl != null &&
        ctrl.value.isInitialized &&
        _rawDragOffsetX.abs() >= _seekSwipeMinDistance) {
      final seconds = _seekSwipeSecondsForOffset(_rawDragOffsetX);
      final target = _clampPosition(
        _seekDragStartPosition + Duration(seconds: seconds),
        ctrl.value.duration,
      );
      _requestSeek(target);
      _showSeekHint(seconds, target: target);
    } else {
      _hideSeekHint();
    }
    _rawDragOffsetX = 0;
    if (mounted) setState(() => _isSeekScrubbing = false);
  }

  void _handleHorizontalDragCancel() {
    if (_isApplyingSeek) return;
    _rawDragOffsetX = 0;
    _hideSeekHint();
  }

  int _seekSwipeSecondsForOffset(double offsetX) {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return 0;

    final width = MediaQuery.sizeOf(context).width;
    final durationSeconds = ctrl.value.duration.inSeconds;
    if (width <= 0 || durationSeconds <= 0) return 0;

    final maxSeconds = (durationSeconds * _seekSwipeDurationPercent)
        .round()
        .clamp(10, 180);
    return (offsetX / width * maxSeconds).round();
  }

  Duration _clampPosition(Duration position, Duration duration) {
    if (position.isNegative) return Duration.zero;
    if (duration > Duration.zero) {
      final maxSeekPosition =
          duration > _endSeekSafetyMargin
              ? duration - _endSeekSafetyMargin
              : duration;
      if (position > maxSeekPosition) return maxSeekPosition;
    }
    return position;
  }

  void _seek(int seconds) {
    final ctrl = _ctrl;
    if (_isApplyingSeek || ctrl == null || !ctrl.value.isInitialized) return;
    final duration = ctrl.value.duration;
    final pos = ctrl.value.position + Duration(seconds: seconds);
    final target = _clampPosition(pos, duration);
    _requestSeek(target);
  }

  Future<void> _requestSeek(
    Duration target, {
    bool resumePlayback = false,
  }) async {
    final ctrl = _ctrl;
    if (_isApplyingSeek || ctrl == null || !ctrl.value.isInitialized) return;

    final safeTarget = _clampPosition(target, ctrl.value.duration);
    setState(() {
      _isApplyingSeek = true;
      _desiredPlaying = null;
    });

    try {
      await ctrl.seekTo(safeTarget).timeout(_seekTimeout);
      if (!mounted || _ctrl != ctrl) return;
      if (resumePlayback && !ctrl.value.isPlaying) {
        await ctrl.play().timeout(_seekTimeout);
      }
    } on TimeoutException {
      // Network-backed progressive streams can hang while resolving a seek.
    } catch (_) {
      // ExoPlayer source errors are surfaced asynchronously; keep UI usable.
    } finally {
      if (mounted && _ctrl == ctrl) {
        setState(() {
          _isApplyingSeek = false;
          _isPlaying = ctrl.value.isPlaying;
          _desiredPlaying = null;
        });
      } else {
        _isApplyingSeek = false;
      }
    }
  }

  void _handleProgressDragStart() {
    if (!mounted || _isApplyingSeek) return;
    setState(() {
      _isSeekScrubbing = true;
      _showSeekFeedback = false;
    });
  }

  void _handleProgressDragEnd() {
    if (!mounted) return;
    setState(() {
      _isSeekScrubbing = false;
      _seekFeedbackSeconds = null;
      _seekFeedbackTarget = null;
    });
  }

  void _showSeekHint(int seconds, {Duration? target}) {
    final feedbackId = ++_seekFeedbackId;
    setState(() {
      _seekFeedbackSeconds = seconds;
      _seekFeedbackTarget = target;
      _showSeekFeedback = true;
    });

    Future.delayed(const Duration(milliseconds: 1100), () {
      if (!mounted || feedbackId != _seekFeedbackId) return;
      setState(() => _showSeekFeedback = false);
    });

    Future.delayed(const Duration(milliseconds: 1340), () {
      if (!mounted || feedbackId != _seekFeedbackId) return;
      setState(() {
        _seekFeedbackSeconds = null;
        _seekFeedbackTarget = null;
      });
    });
  }

  void _hideSeekHint() {
    final feedbackId = ++_seekFeedbackId;
    setState(() {
      _showSeekFeedback = false;
      _isSeekScrubbing = false;
    });

    Future.delayed(const Duration(milliseconds: 180), () {
      if (!mounted || feedbackId != _seekFeedbackId) return;
      setState(() {
        _seekFeedbackSeconds = null;
        _seekFeedbackTarget = null;
      });
    });
  }

  void _togglePlay() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    final nextPlaying = !(_desiredPlaying ?? _isPlaying);
    setState(() {
      _isPlaying = nextPlaying;
      _desiredPlaying = nextPlaying;
    });
    _applyDesiredPlayState();
  }

  Future<void> _applyDesiredPlayState() async {
    if (_isApplyingPlayState) return;

    _isApplyingPlayState = true;
    try {
      while (mounted) {
        final ctrl = _ctrl;
        final desiredPlaying = _desiredPlaying;
        if (ctrl == null ||
            desiredPlaying == null ||
            !ctrl.value.isInitialized) {
          _desiredPlaying = null;
          return;
        }

        var commandSucceeded = true;
        try {
          if (ctrl.value.isPlaying != desiredPlaying) {
            if (desiredPlaying) {
              await ctrl.play();
            } else {
              await ctrl.pause();
            }
          }
        } catch (_) {
          commandSucceeded = false;
          // Keep the UI responsive; the controller listener will resync state.
        }

        if (!mounted || _ctrl != ctrl) return;
        if (_desiredPlaying == desiredPlaying) {
          setState(() {
            _desiredPlaying = null;
            _isPlaying =
                commandSucceeded ? desiredPlaying : ctrl.value.isPlaying;
          });
          return;
        }
      }
    } finally {
      _isApplyingPlayState = false;
      if (mounted && _desiredPlaying != null) {
        _applyDesiredPlayState();
      }
    }
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  void _handleProgressPlayingChanged(bool playing) {
    if (!mounted) return;
    setState(() {
      _isPlaying = playing;
      _desiredPlaying = null;
    });
  }

  Future<void> _toggleFavorite() async {
    final item = _items[_index];
    final newVal = !item.isFavorite;
    setState(() => _items[_index] = item.copyWith(isFavorite: newVal));
    try {
      await EmbyService().setFavorite(item.id, favorite: newVal);
    } catch (_) {
      setState(
        () => _items[_index] = item.copyWith(isFavorite: item.isFavorite),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final item = _items[_index];
    final isSeeking = _isApplyingSeek;
    final hideCenterControls = isSeeking || _isSeekScrubbing;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBackPressed();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _handleVerticalDragStart,
          onVerticalDragUpdate: _handleVerticalDragUpdate,
          onVerticalDragEnd: _handleVerticalDragEnd,
          onVerticalDragCancel: _handleVerticalDragCancel,
          onHorizontalDragStart: _handleHorizontalDragStart,
          onHorizontalDragUpdate: _handleHorizontalDragUpdate,
          onHorizontalDragEnd: _handleHorizontalDragEnd,
          onHorizontalDragCancel: _handleHorizontalDragCancel,
          onDoubleTapDown: (d) {
            if (isSeeking) return;
            final half = MediaQuery.of(context).size.width / 2;
            final seconds = d.localPosition.dx < half ? -15 : 15;
            _seek(seconds);
            _showSeekHint(seconds);
          },
          onDoubleTap: () {},
          onTap: _toggleControls,
          child: ClipRect(
            child: Transform.translate(
              offset: Offset(0, _dragOffsetY),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ctrl != null && ctrl.value.isInitialized)
                    Center(
                      child: AspectRatio(
                        aspectRatio: ctrl.value.aspectRatio,
                        child: VideoPlayer(ctrl),
                      ),
                    )
                  else
                    const Center(
                      child: CircularProgressIndicator(color: Colors.green),
                    ),
                  if (!_isFullscreen || _showControls)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Colors.black87, Colors.transparent],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (item.overview.isNotEmpty)
                              Text(
                                item.overview,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            const SizedBox(height: 8),
                            if (ctrl != null)
                              _ProgressBar(
                                ctrl: ctrl,
                                enabled: !isSeeking,
                                onDragStart: _handleProgressDragStart,
                                onDragEnd: _handleProgressDragEnd,
                                onSeekRequested: _requestSeek,
                                onPlayingChanged: _handleProgressPlayingChanged,
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_showControls)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                              ),
                              onPressed: _handleBackPressed,
                            ),
                            const Spacer(),
                            if (_isFullscreen) ...[
                              IconButton(
                                tooltip:
                                    _playbackOrientation ==
                                            _PlaybackOrientation.landscape
                                        ? '切换竖屏'
                                        : '切换横屏',
                                icon: Icon(
                                  _playbackOrientation ==
                                          _PlaybackOrientation.landscape
                                      ? Icons.stay_current_portrait
                                      : Icons.stay_current_landscape,
                                  color: Colors.white,
                                ),
                                onPressed: _togglePlaybackOrientation,
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: '退出全屏',
                                icon: const Icon(
                                  Icons.fullscreen_exit,
                                  color: Colors.white,
                                ),
                                onPressed: _exitFullscreen,
                              ),
                            ] else
                              IconButton(
                                tooltip: '全屏播放',
                                icon: const Icon(
                                  Icons.fullscreen,
                                  color: Colors.white,
                                ),
                                onPressed: _enterFullscreen,
                              ),
                            const SizedBox(width: 8),
                            Text(
                              '${_index + 1} / ${_items.length}',
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(width: 16),
                          ],
                        ),
                      ),
                    ),
                  if (_showControls && ctrl != null && !hideCenterControls)
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            iconSize: 40,
                            icon: const _SeekButtonIcon(seconds: -15),
                            onPressed: isSeeking ? null : () => _seek(-15),
                          ),
                          const SizedBox(width: 48),
                          IconButton(
                            iconSize: 56,
                            icon: Icon(
                              _isPlaying
                                  ? Icons.pause_circle
                                  : Icons.play_circle,
                              color: Colors.white,
                            ),
                            onPressed: isSeeking ? null : _togglePlay,
                          ),
                          const SizedBox(width: 48),
                          IconButton(
                            iconSize: 40,
                            icon: const _SeekButtonIcon(seconds: 15),
                            onPressed: isSeeking ? null : () => _seek(15),
                          ),
                        ],
                      ),
                    ),
                  if (isSeeking)
                    const Center(
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 3,
                        ),
                      ),
                    ),
                  if (_seekFeedbackSeconds != null)
                    Align(
                      alignment: const Alignment(0, -0.38),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: _showSeekFeedback ? 1 : 0,
                        curve: Curves.easeOutCubic,
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey(_seekFeedbackId),
                          tween: Tween(begin: 0.86, end: 1),
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutBack,
                          builder: (context, scale, child) {
                            return Transform.scale(scale: scale, child: child);
                          },
                          child: _SeekFeedback(
                            seconds: _seekFeedbackSeconds!,
                            target: _seekFeedbackTarget,
                            isScrubbing: _isSeekScrubbing,
                          ),
                        ),
                      ),
                    ),
                  if (!_isFullscreen || _showControls)
                    Positioned(
                      right: 12,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              iconSize: 36,
                              icon: Icon(
                                item.isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color:
                                    item.isFavorite ? Colors.red : Colors.white,
                              ),
                              onPressed: _toggleFavorite,
                            ),
                            Text(
                              item.isFavorite ? '已收藏' : '收藏',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatefulWidget {
  final VideoPlayerController ctrl;
  final bool enabled;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final _SeekRequestCallback onSeekRequested;
  final ValueChanged<bool> onPlayingChanged;
  const _ProgressBar({
    required this.ctrl,
    required this.enabled,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onSeekRequested,
    required this.onPlayingChanged,
  });

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _SeekButtonIcon extends StatelessWidget {
  final int seconds;

  const _SeekButtonIcon({required this.seconds});

  @override
  Widget build(BuildContext context) {
    final isForward = seconds > 0;

    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..scale(isForward ? -1.0 : 1.0, 1.0),
            child: const Icon(Icons.replay, color: Colors.white, size: 36),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '${isForward ? '+' : '-'}${seconds.abs()}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekFeedback extends StatelessWidget {
  final int seconds;
  final Duration? target;
  final bool isScrubbing;

  const _SeekFeedback({
    required this.seconds,
    required this.target,
    required this.isScrubbing,
  });

  @override
  Widget build(BuildContext context) {
    final isForward = seconds > 0;
    final isNeutral = seconds == 0;
    final icon =
        isNeutral
            ? Icons.drag_handle
            : isForward
            ? Icons.fast_forward
            : Icons.fast_rewind;
    final secondsText =
        isNeutral ? '0s' : '${isForward ? '+' : '-'}${seconds.abs()}s';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: SizedBox(
        width: isScrubbing ? 168 : 96,
        height: isScrubbing ? 86 : 70,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: isScrubbing ? 26 : 24),
            const SizedBox(height: 4),
            Text(
              secondsText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (isScrubbing && target != null) ...[
              const SizedBox(height: 2),
              Text(
                _formatDuration(target!),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue;
  bool _wasPlayingBeforeDrag = false;

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _ProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ctrl == widget.ctrl) return;
    oldWidget.ctrl.removeListener(_handleControllerChanged);
    widget.ctrl.addListener(_handleControllerChanged);
    _dragValue = null;
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dur = widget.ctrl.value.duration.inMilliseconds;
    final pos =
        _dragValue ?? widget.ctrl.value.position.inMilliseconds.toDouble();
    final enabled = widget.enabled && dur > 0;

    return Row(
      children: [
        Text(
          _fmt(pos.toInt()),
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
        Expanded(
          child: SizedBox(
            height: 44,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                activeTrackColor: Colors.green,
                inactiveTrackColor: Colors.white30,
                overlayColor: Colors.white.withValues(alpha: 0.14),
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: dur > 0 ? pos.clamp(0, dur.toDouble()) : 0,
                min: 0,
                max: dur > 0 ? dur.toDouble() : 1,
                onChangeStart:
                    enabled
                        ? (_) {
                          _wasPlayingBeforeDrag = widget.ctrl.value.isPlaying;
                          widget.onDragStart();
                          widget.onPlayingChanged(false);
                          unawaited(widget.ctrl.pause().catchError((_) {}));
                        }
                        : null,
                onChanged:
                    enabled ? (v) => setState(() => _dragValue = v) : null,
                onChangeEnd:
                    enabled
                        ? (v) async {
                          try {
                            await widget.onSeekRequested(
                              Duration(milliseconds: v.toInt()),
                              resumePlayback: _wasPlayingBeforeDrag,
                            );
                            widget.onPlayingChanged(
                              widget.ctrl.value.isPlaying,
                            );
                          } finally {
                            if (mounted) {
                              setState(() => _dragValue = null);
                            } else {
                              _dragValue = null;
                            }
                            widget.onDragEnd();
                          }
                        }
                        : null,
              ),
            ),
          ),
        ),
        Text(
          _fmt(dur),
          style: const TextStyle(color: Colors.grey, fontSize: 11),
        ),
      ],
    );
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
