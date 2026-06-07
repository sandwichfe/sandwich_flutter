// Emby 播放页 seek 反馈组件：显示快进、快退和拖动进度时的提示。
part of 'emby_stream_page.dart';

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
