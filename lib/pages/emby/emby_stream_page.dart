import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../../models/emby_models.dart';
import '../../services/emby_service.dart';

part 'emby_stream_progress_bar.dart';
part 'emby_stream_fullscreen.dart';
part 'emby_stream_gestures.dart';
part 'emby_stream_playlist.dart';
part 'emby_stream_seek_feedback.dart';
part 'emby_stream_toast.dart';
part 'emby_stream_view.dart';

enum _PlaybackOrientation { portrait, landscape }

enum _PlaybackMode { sequential, random }

typedef _SeekRequestCallback =
    Future<void> Function(Duration target, {bool resumePlayback});

typedef EmbyStreamPageLoader =
    Future<({List<EmbyItem> items, int total})> Function(int startIndex);

class EmbyStreamResult {
  final List<EmbyItem> items;
  final int currentIndex;
  final Duration currentPosition;
  final int? totalCount;

  const EmbyStreamResult({
    required this.items,
    required this.currentIndex,
    this.currentPosition = Duration.zero,
    this.totalCount,
  });
}

class EmbyStreamPage extends StatefulWidget {
  final List<EmbyItem> items;
  final int initialIndex;
  final Duration initialPosition;
  final int? totalCount;
  final EmbyStreamPageLoader? onLoadMore;
  const EmbyStreamPage({
    super.key,
    required this.items,
    required this.initialIndex,
    this.initialPosition = Duration.zero,
    this.totalCount,
    this.onLoadMore,
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
  static const String _playbackModeStorageKey = 'emby_playback_mode';
  static const String _randomPlaybackModeValue = 'random';

  late int _index;
  late List<EmbyItem> _items;
  late final AnimationController _slideController;
  final Random _random = Random();
  final List<int> _randomQueue = [];
  final List<int> _randomHistory = [];
  VideoPlayerController? _ctrl;
  bool _showControls = false;
  bool _isSwitchingVideo = false;
  bool _isLoadingMoreItems = false;
  bool _isAdvancingAfterEnd = false;
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
  OverlayEntry? _toastOverlayEntry;
  Timer? _toastTimer;
  _PlaybackOrientation _playbackOrientation = _PlaybackOrientation.portrait;
  _PlaybackMode _playbackMode = _PlaybackMode.sequential;
  int? _totalCount;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _items = List.of(widget.items);
    _totalCount = widget.totalCount;
    _slideController = AnimationController(
      vsync: this,
      duration: _settleDuration,
    );
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _restorePlaybackMode();
    _play(_index, position: widget.initialPosition);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _hideToast();
    _slideController.dispose();
    _ctrl?.removeListener(_handlePlaybackControllerChanged);
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _play(int index, {Duration position = Duration.zero}) async {
    final requestId = ++_playRequestId;
    final oldCtrl = _ctrl;
    if (oldCtrl != null) {
      oldCtrl.removeListener(_handlePlaybackControllerChanged);
      if (mounted) {
        setState(() {
          _ctrl = null;
          _isPlaying = false;
          _desiredPlaying = null;
          _showControls = false;
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
      _showControls = false;
    });
    if (position > Duration.zero && ctrl.value.duration > Duration.zero) {
      await ctrl.seekTo(_clampPosition(position, ctrl.value.duration));
      if (!mounted || requestId != _playRequestId || _ctrl != ctrl) return;
    }
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

    final duration = ctrl.value.duration;
    if (!_isAdvancingAfterEnd &&
        !_isApplyingSeek &&
        duration > Duration.zero &&
        ctrl.value.position >= duration &&
        !ctrl.value.isPlaying) {
      _isAdvancingAfterEnd = true;
      _switchToNext().whenComplete(() => _isAdvancingAfterEnd = false);
    }
  }

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  Widget build(BuildContext context) => _buildStreamView(context);
}
