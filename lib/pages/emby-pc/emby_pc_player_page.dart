import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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
  VideoPlayerController? _controller;
  bool _loading = true;
  bool _muted = false;
  String _error = '';
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  // 章节和继续播放都换算为 Emby ticks 后从指定位置起播。
  Future<void> _initializePlayer() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(EmbyPcService.instance.streamUrl(widget.item.id)),
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      final start = Duration(microseconds: widget.startPositionTicks ~/ 10);
      if (start > Duration.zero && start < controller.value.duration) {
        await controller.seekTo(start);
      }
      await controller.play();
      controller.addListener(_refreshPlayerState);
      _progressTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _reportProgress('/Sessions/Playing/Progress', controller),
      );
      _reportProgress('/Sessions/Playing', controller);
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '视频加载失败：$error';
        });
      }
    }
  }

  void _refreshPlayerState() {
    if (mounted) setState(() {});
  }

  void _reportProgress(String eventPath, VideoPlayerController controller) {
    final ticks = controller.value.position.inMicroseconds * 10;
    EmbyPcService.instance.reportPlayback(
      itemId: widget.item.id,
      eventPath: eventPath,
      positionTicks: ticks,
      paused: !controller.value.isPlaying,
    );
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    controller.value.isPlaying ? await controller.pause() : await controller.play();
    _reportProgress('/Sessions/Playing/Progress', controller);
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null) return;
    _muted = !_muted;
    await controller.setVolume(_muted ? 0 : 1);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      _reportProgress('/Sessions/Playing/Stopped', controller);
    }
    _progressTimer?.cancel();
    _controller?.removeListener(_refreshPlayerState);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.item.name, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : _error.isNotEmpty
                ? _PlayerMessage(icon: Icons.error_outline, text: _error)
                : controller == null
                    ? const _PlayerMessage(
                        icon: Icons.videocam_off_outlined,
                        text: '播放器不可用',
                      )
                    : Column(
                        children: [
                          Expanded(
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: controller.value.aspectRatio > 0
                                    ? controller.value.aspectRatio
                                    : 16 / 9,
                                child: VideoPlayer(controller),
                              ),
                            ),
                          ),
                          _PlayerControls(
                            controller: controller,
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

class _PlayerControls extends StatelessWidget {
  final VideoPlayerController controller;
  final bool muted;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleMute;

  const _PlayerControls({
    required this.controller,
    required this.muted,
    required this.onTogglePlay,
    required this.onToggleMute,
  });

  @override
  Widget build(BuildContext context) {
    final position = controller.value.position;
    final duration = controller.value.duration;
    final max = duration.inMilliseconds.toDouble().clamp(1, double.infinity).toDouble();
    final current = position.inMilliseconds.toDouble().clamp(0, max).toDouble();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: Row(
          children: [
            IconButton(
              tooltip: controller.value.isPlaying ? '暂停' : '播放',
              color: Colors.white,
              onPressed: onTogglePlay,
              icon: Icon(
                controller.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
            Expanded(
              child: Slider(
                value: current,
                max: max,
                onChanged: (value) => controller.seekTo(
                  Duration(milliseconds: value.round()),
                ),
              ),
            ),
            Text(
              '${_formatDuration(position)} / ${_formatDuration(duration)}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: muted ? '取消静音' : '静音',
              color: Colors.white,
              onPressed: onToggleMute,
              icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
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
