// Emby 播放页全屏相关逻辑：处理全屏进入/退出、横竖屏切换，以及返回结果。
part of 'emby_stream_page.dart';

extension _EmbyStreamFullscreen on _EmbyStreamPageState {
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
    _updateState(() => _playbackOrientation = orientation);
  }

  Future<void> _togglePlaybackOrientation() {
    final next =
        _playbackOrientation == _PlaybackOrientation.landscape
            ? _PlaybackOrientation.portrait
            : _PlaybackOrientation.landscape;
    return _applyPlaybackOrientation(next);
  }

  Future<void> _enterFullscreen() async {
    _updateState(() => _isFullscreen = true);
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
    _updateState(() {
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

    _popWithResult();
  }

  Future<void> _openGridPage() async {
    if (_isFullscreen ||
        _playbackOrientation == _PlaybackOrientation.landscape) {
      await _exitFullscreen();
    }

    _popWithResult();
  }

  void _popWithResult() {
    if (!mounted) return;
    Navigator.pop(
      context,
      EmbyStreamResult(
        items: _items,
        currentIndex: _index,
        currentPosition: _currentPosition,
        totalCount: _totalCount,
      ),
    );
  }
}
