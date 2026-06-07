// Emby 播放页 Toast overlay：在播放界面上方显示临时提示。
part of 'emby_stream_page.dart';

extension _EmbyStreamToast on _EmbyStreamPageState {
  void _showToast(String message) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    _hideToast();
    final entry = OverlayEntry(
      builder:
          (context) => Positioned.fill(
            child: IgnorePointer(
              child: SafeArea(
                child: Align(
                  alignment: const Alignment(0, -0.28),
                  child: Material(
                    color: Colors.transparent,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        child: Text(
                          message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
    );

    _toastOverlayEntry = entry;
    overlay.insert(entry);
    _toastTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_toastOverlayEntry == entry) {
        _toastOverlayEntry = null;
        _toastTimer = null;
      }
      entry.remove();
    });
  }

  void _hideToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    _toastOverlayEntry?.remove();
    _toastOverlayEntry = null;
  }
}
