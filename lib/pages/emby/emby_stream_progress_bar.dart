// Emby 播放页进度条组件：显示播放进度，并处理拖动 seek 交互。
part of 'emby_stream_page.dart';

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
