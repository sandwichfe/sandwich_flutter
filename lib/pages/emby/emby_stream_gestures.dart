// Emby 播放页手势逻辑：处理上下滑切换、左右滑/双击 seek，以及进度拖动。
part of 'emby_stream_page.dart';

extension _EmbyStreamGestures on _EmbyStreamPageState {
  Duration get _currentPosition {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return Duration.zero;
    return _clampPosition(ctrl.value.position, ctrl.value.duration);
  }

  double _visualDragOffset(double rawOffset) {
    if ((_index == 0 && rawOffset > 0) || (!_canMoveForward && rawOffset < 0)) {
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
    _slideController.duration =
        duration ?? _EmbyStreamPageState._settleDuration;
    final animation = Tween<double>(
      begin: _dragOffsetY,
      end: target,
    ).animate(CurvedAnimation(parent: _slideController, curve: curve));

    void updateOffset() {
      if (mounted) _updateState(() => _dragOffsetY = animation.value);
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

  void _handleVerticalDragStart(DragStartDetails details) {
    if (_isSwitchingVideo || _isLoadingMoreItems) return;
    _slideController.stop();
    _rawDragOffsetY = 0;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_isSwitchingVideo || _isLoadingMoreItems) return;
    _updateState(() {
      _rawDragOffsetY += details.delta.dy;
      _dragOffsetY = _visualDragOffset(_rawDragOffsetY);
    });
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (_isSwitchingVideo || _isLoadingMoreItems) return;

    final height = MediaQuery.sizeOf(context).height;
    final velocity = details.primaryVelocity ?? 0;
    final distanceThreshold = height * 0.16;
    final shouldNext =
        _canMoveForward &&
        (_rawDragOffsetY < -distanceThreshold ||
            velocity < -_EmbyStreamPageState._switchVelocity);
    final shouldPrev =
        (_playbackMode == _PlaybackMode.random || _index > 0) &&
        (_rawDragOffsetY > distanceThreshold ||
            velocity > _EmbyStreamPageState._switchVelocity);

    if (shouldNext) {
      _switchToNext(exitOffset: -height);
    } else if (shouldPrev) {
      _switchToPrevious(exitOffset: height);
    } else {
      _rawDragOffsetY = 0;
      _animateDragTo(0);
    }
  }

  void _handleVerticalDragCancel() {
    if (_isSwitchingVideo || _isLoadingMoreItems) return;
    _rawDragOffsetY = 0;
    _animateDragTo(0);
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    final ctrl = _ctrl;
    if (_isApplyingSeek || ctrl == null || !ctrl.value.isInitialized) return;
    _rawDragOffsetX = 0;
    _seekDragStartPosition = ctrl.value.position;
    _updateState(() {
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
    _updateState(() {
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
        _rawDragOffsetX.abs() >= _EmbyStreamPageState._seekSwipeMinDistance) {
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
    if (mounted) _updateState(() => _isSeekScrubbing = false);
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

    final maxSeconds = (durationSeconds *
            _EmbyStreamPageState._seekSwipeDurationPercent)
        .round()
        .clamp(10, 180);
    return (offsetX / width * maxSeconds).round();
  }

  Duration _clampPosition(Duration position, Duration duration) {
    if (position.isNegative) return Duration.zero;
    if (duration > Duration.zero) {
      final maxSeekPosition =
          duration > _EmbyStreamPageState._endSeekSafetyMargin
              ? duration - _EmbyStreamPageState._endSeekSafetyMargin
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
    _updateState(() {
      _isApplyingSeek = true;
      _desiredPlaying = null;
    });

    try {
      await ctrl.seekTo(safeTarget).timeout(_EmbyStreamPageState._seekTimeout);
      if (!mounted || _ctrl != ctrl) return;
      if (resumePlayback && !ctrl.value.isPlaying) {
        await ctrl.play().timeout(_EmbyStreamPageState._seekTimeout);
      }
    } on TimeoutException {
      // Network-backed progressive streams can hang while resolving a seek.
    } catch (_) {
      // ExoPlayer source errors are surfaced asynchronously; keep UI usable.
    } finally {
      if (mounted && _ctrl == ctrl) {
        _updateState(() {
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
    _updateState(() {
      _isSeekScrubbing = true;
      _showSeekFeedback = false;
    });
  }

  void _handleProgressDragEnd() {
    if (!mounted) return;
    _updateState(() {
      _isSeekScrubbing = false;
      _seekFeedbackSeconds = null;
      _seekFeedbackTarget = null;
    });
  }

  void _showSeekHint(int seconds, {Duration? target}) {
    final feedbackId = ++_seekFeedbackId;
    _updateState(() {
      _seekFeedbackSeconds = seconds;
      _seekFeedbackTarget = target;
      _showSeekFeedback = true;
    });

    Future.delayed(const Duration(milliseconds: 1100), () {
      if (!mounted || feedbackId != _seekFeedbackId) return;
      _updateState(() => _showSeekFeedback = false);
    });

    Future.delayed(const Duration(milliseconds: 1340), () {
      if (!mounted || feedbackId != _seekFeedbackId) return;
      _updateState(() {
        _seekFeedbackSeconds = null;
        _seekFeedbackTarget = null;
      });
    });
  }

  void _hideSeekHint() {
    final feedbackId = ++_seekFeedbackId;
    _updateState(() {
      _showSeekFeedback = false;
      _isSeekScrubbing = false;
    });

    Future.delayed(const Duration(milliseconds: 180), () {
      if (!mounted || feedbackId != _seekFeedbackId) return;
      _updateState(() {
        _seekFeedbackSeconds = null;
        _seekFeedbackTarget = null;
      });
    });
  }
}
