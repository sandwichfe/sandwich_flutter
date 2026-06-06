import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../models/emby_models.dart';
import '../services/emby_service.dart';

class EmbyStreamPage extends StatefulWidget {
  final List<EmbyItem> items;
  final int initialIndex;
  const EmbyStreamPage({super.key, required this.items, required this.initialIndex});

  @override
  State<EmbyStreamPage> createState() => _EmbyStreamPageState();
}

class _EmbyStreamPageState extends State<EmbyStreamPage> {
  late int _index;
  VideoPlayerController? _ctrl;
  bool _showControls = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    _play(_index);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _play(int index) async {
    await _ctrl?.dispose();
    _ctrl = null;
    setState(() {});

    final url = EmbyService().getStreamUrl(widget.items[index].id);
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    await ctrl.initialize();
    ctrl.play();
    if (mounted) setState(() => _ctrl = ctrl);
  }

  void _next() {
    if (_index < widget.items.length - 1) {
      _index++;
      _play(_index);
    }
  }

  void _prev() {
    if (_index > 0) {
      _index--;
      _play(_index);
    }
  }

  void _seek(int seconds) {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    final pos = ctrl.value.position + Duration(seconds: seconds);
    ctrl.seekTo(pos.isNegative ? Duration.zero : pos);
  }

  void _togglePlay() => _ctrl?.value.isPlaying == true ? _ctrl?.pause() : _ctrl?.play();

  void _toggleControls() => setState(() => _showControls = !_showControls);

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final item = widget.items[_index];

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onVerticalDragEnd: (d) {
          if (d.primaryVelocity == null) return;
          if (d.primaryVelocity! < -300) _next();
          if (d.primaryVelocity! > 300) _prev();
        },
        onDoubleTapDown: (d) {
          final half = MediaQuery.of(context).size.width / 2;
          _seek(d.localPosition.dx < half ? -15 : 15);
        },
        onDoubleTap: () {},
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video
            if (ctrl != null && ctrl.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: ctrl.value.aspectRatio,
                  child: VideoPlayer(ctrl),
                ),
              )
            else
              const Center(child: CircularProgressIndicator(color: Colors.green)),

            // Info overlay (always visible at bottom)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                decoration: const BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                )),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    if (item.overview.isNotEmpty)
                      Text(item.overview, style: const TextStyle(color: Colors.grey, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 8),
                    if (ctrl != null) _ProgressBar(ctrl: ctrl, onDragStart: () {}, onDragEnd: () {}),
                  ],
                ),
              ),
            ),

            // Controls overlay
            if (_showControls)
              Positioned(
                top: 0, left: 0, right: 0,
                child: SafeArea(
                  child: Row(
                    children: [
                      IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                      const Spacer(),
                      Text('${_index + 1} / ${widget.items.length}', style: const TextStyle(color: Colors.white)),
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
                    IconButton(iconSize: 40, icon: const Icon(Icons.replay_10, color: Colors.white), onPressed: () => _seek(-10)),
                    const SizedBox(width: 16),
                    IconButton(
                      iconSize: 56,
                      icon: Icon(ctrl.value.isPlaying ? Icons.pause_circle : Icons.play_circle, color: Colors.white),
                      onPressed: _togglePlay,
                    ),
                    const SizedBox(width: 16),
                    IconButton(iconSize: 40, icon: const Icon(Icons.forward_10, color: Colors.white), onPressed: () => _seek(10)),
                  ],
                ),
              ),

            // Swipe hints
            if (_showControls) ...[
              if (_index > 0)
                const Positioned(top: 80, left: 0, right: 0, child: Icon(Icons.keyboard_arrow_up, color: Colors.white54, size: 28)),
              if (_index < widget.items.length - 1)
                const Positioned(bottom: 120, left: 0, right: 0, child: Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 28)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends StatefulWidget {
  final VideoPlayerController ctrl;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  const _ProgressBar({required this.ctrl, required this.onDragStart, required this.onDragEnd});

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  Widget build(BuildContext context) {
    final dur = widget.ctrl.value.duration.inMilliseconds;
    final pos = _dragValue ?? widget.ctrl.value.position.inMilliseconds.toDouble();

    return Row(
      children: [
        Text(_fmt(pos.toInt()), style: const TextStyle(color: Colors.white, fontSize: 11)),
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
              onChangeStart: (_) { widget.onDragStart(); widget.ctrl.pause(); },
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
        Text(_fmt(dur), style: const TextStyle(color: Colors.grey, fontSize: 11)),
      ],
    );
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
