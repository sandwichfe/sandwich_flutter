import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../models/emby_models.dart';
import '../../services/emby_service.dart';

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

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _items = List.of(widget.items);
    _slideController = AnimationController(
      vsync: this,
      duration: _settleDuration,
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    _play(_index);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _slideController.dispose();
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _play(int index) async {
    final requestId = ++_playRequestId;
    final oldCtrl = _ctrl;
    if (oldCtrl != null) {
      if (mounted) {
        setState(() => _ctrl = null);
        await WidgetsBinding.instance.endOfFrame;
      } else {
        _ctrl = null;
      }
      await oldCtrl.dispose();
    }

    final url = EmbyService().getStreamUrl(_items[index].id);
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    await ctrl.initialize();
    ctrl.play();
    if (!mounted || requestId != _playRequestId) {
      await ctrl.dispose();
      return;
    }
    setState(() => _ctrl = ctrl);
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
  }) async {
    _slideController.stop();
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
    if (exitOffset != null) await _animateDragTo(exitOffset);
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
    if (ctrl == null || !ctrl.value.isInitialized) return;
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
    if (ctrl == null || !ctrl.value.isInitialized) return;
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
    final ctrl = _ctrl;
    if (ctrl != null &&
        ctrl.value.isInitialized &&
        _rawDragOffsetX.abs() >= _seekSwipeMinDistance) {
      final seconds = _seekSwipeSecondsForOffset(_rawDragOffsetX);
      final target = _clampPosition(
        _seekDragStartPosition + Duration(seconds: seconds),
        ctrl.value.duration,
      );
      ctrl.seekTo(target);
      _showSeekHint(seconds, target: target);
    } else {
      _hideSeekHint();
    }
    _rawDragOffsetX = 0;
    if (mounted) setState(() => _isSeekScrubbing = false);
  }

  void _handleHorizontalDragCancel() {
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
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  void _seek(int seconds) {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    final duration = ctrl.value.duration;
    final pos = ctrl.value.position + Duration(seconds: seconds);
    final target = _clampPosition(pos, duration);
    ctrl.seekTo(target);
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

  void _togglePlay() =>
      _ctrl?.value.isPlaying == true ? _ctrl?.pause() : _ctrl?.play();
  void _toggleControls() => setState(() => _showControls = !_showControls);

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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _items);
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
                              onDragStart: () {},
                              onDragEnd: () {},
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
                              onPressed: () => Navigator.pop(context, _items),
                            ),
                            const Spacer(),
                            Text(
                              '${_index + 1} / ${_items.length}',
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(width: 16),
                          ],
                        ),
                      ),
                    ),
                  if (_showControls && ctrl != null)
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            iconSize: 40,
                            icon: const _SeekButtonIcon(seconds: -15),
                            onPressed: () => _seek(-15),
                          ),
                          const SizedBox(width: 48),
                          IconButton(
                            iconSize: 56,
                            icon: Icon(
                              ctrl.value.isPlaying
                                  ? Icons.pause_circle
                                  : Icons.play_circle,
                              color: Colors.white,
                            ),
                            onPressed: _togglePlay,
                          ),
                          const SizedBox(width: 48),
                          IconButton(
                            iconSize: 40,
                            icon: const _SeekButtonIcon(seconds: 15),
                            onPressed: () => _seek(15),
                          ),
                        ],
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
                  Positioned(
                    right: 12,
                    bottom: 120,
                    child: Column(
                      children: [
                        IconButton(
                          iconSize: 36,
                          icon: Icon(
                            item.isFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: item.isFavorite ? Colors.red : Colors.white,
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
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  const _ProgressBar({
    required this.ctrl,
    required this.onDragStart,
    required this.onDragEnd,
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

    return Row(
      children: [
        Text(
          _fmt(pos.toInt()),
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: Colors.green,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: dur > 0 ? pos.clamp(0, dur.toDouble()) : 0,
              min: 0,
              max: dur > 0 ? dur.toDouble() : 1,
              onChangeStart: (_) {
                widget.onDragStart();
                widget.ctrl.pause();
              },
              onChanged: (v) => setState(() => _dragValue = v),
              onChangeEnd: (v) {
                widget.ctrl.seekTo(Duration(milliseconds: v.toInt()));
                widget.ctrl.play();
                _dragValue = null;
                widget.onDragEnd();
              },
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
