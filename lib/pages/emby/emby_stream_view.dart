// Emby 播放页界面叠层：构建页面 UI、顶部/底部控制栏，以及收藏按钮。
part of 'emby_stream_page.dart';

extension _EmbyStreamView on _EmbyStreamPageState {
  Widget _buildStreamView(BuildContext context) {
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
          onTap: _handlePlaybackSurfaceTap,
          child: ClipRect(
            child: Transform.translate(
              offset: Offset(0, _dragOffsetY),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildVideoSurface(ctrl),
                  if (!_isFullscreen || _showControls)
                    _buildBottomInfoPanel(ctrl, item, isSeeking),
                  if (_showControls) _buildTopControls(),
                  if (_showControls &&
                      !_isPlaying &&
                      ctrl != null &&
                      !hideCenterControls)
                    _buildCenterPlayButton(isSeeking),
                  if (isSeeking) _buildSeekLoadingIndicator(),
                  if (_seekFeedbackSeconds != null) _buildSeekFeedback(),
                  if (!_isFullscreen || _showControls)
                    _buildFavoriteAction(item),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoSurface(VideoPlayerController? ctrl) {
    if (ctrl != null && ctrl.value.isInitialized) {
      return Center(
        child: AspectRatio(
          aspectRatio: ctrl.value.aspectRatio,
          child: VideoPlayer(ctrl),
        ),
      );
    }

    return const Center(child: CircularProgressIndicator(color: Colors.green));
  }

  Widget _buildBottomInfoPanel(
    VideoPlayerController? ctrl,
    EmbyItem item,
    bool isSeeking,
  ) {
    return Positioned(
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
            _buildPlaybackModeButton(),
            const SizedBox(height: 4),
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
                style: const TextStyle(color: Colors.grey, fontSize: 12),
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
    );
  }

  Widget _buildTopControls() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: _handleBackPressed,
            ),
            const Spacer(),
            if (_isFullscreen) ...[
              IconButton(
                tooltip:
                    _playbackOrientation == _PlaybackOrientation.landscape
                        ? '\u5207\u6362\u7ad6\u5c4f'
                        : '\u5207\u6362\u6a2a\u5c4f',
                icon: Icon(
                  _playbackOrientation == _PlaybackOrientation.landscape
                      ? Icons.stay_current_portrait
                      : Icons.stay_current_landscape,
                  color: Colors.white,
                ),
                onPressed: _togglePlaybackOrientation,
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '\u9000\u51fa\u5168\u5c4f',
                icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
                onPressed: _exitFullscreen,
              ),
            ] else
              IconButton(
                tooltip: '\u5168\u5c4f\u64ad\u653e',
                icon: const Icon(Icons.fullscreen, color: Colors.white),
                onPressed: _enterFullscreen,
              ),
            const SizedBox(width: 8),
            Text(_countLabel, style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '\u5361\u7247\u9875',
              icon: const Icon(Icons.grid_view, color: Colors.white),
              onPressed: _openGridPage,
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterPlayButton(bool isSeeking) {
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.42),
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.30),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: IconButton(
          iconSize: 60,
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints.tightFor(width: 80, height: 80),
          icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
          onPressed: isSeeking ? null : _resumeFromPlayButton,
        ),
      ),
    );
  }

  Widget _buildSeekLoadingIndicator() {
    return const Center(
      child: SizedBox(
        width: 44,
        height: 44,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
      ),
    );
  }

  Widget _buildSeekFeedback() {
    return Align(
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
    );
  }

  Widget _buildFavoriteAction(EmbyItem item) {
    return Positioned(
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
                item.isFavorite ? Icons.favorite : Icons.favorite_border,
                color: item.isFavorite ? Colors.red : Colors.white,
              ),
              onPressed: _toggleFavorite,
            ),
            Text(
              item.isFavorite ? '\u5df2\u6536\u85cf' : '\u6536\u85cf',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackModeButton() {
    return IconButton(
      tooltip:
          _playbackMode == _PlaybackMode.random
              ? '\u968f\u673a\u64ad\u653e'
              : '\u987a\u5e8f\u64ad\u653e',
      icon:
          _isLoadingMoreItems
              ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
              : Icon(
                _playbackMode == _PlaybackMode.random
                    ? Icons.shuffle_rounded
                    : Icons.playlist_play_rounded,
                color:
                    _playbackMode == _PlaybackMode.random
                        ? Colors.green
                        : Colors.white,
              ),
      onPressed: _isLoadingMoreItems ? null : _togglePlaybackMode,
    );
  }
}

extension _EmbyStreamPlaybackControls on _EmbyStreamPageState {
  void _pauseAndShowPlayButton() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    _updateState(() {
      _isPlaying = false;
      _desiredPlaying = false;
      _showControls = true;
    });
    _applyDesiredPlayState();
  }

  void _resumeFromPlayButton() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    _updateState(() {
      _isPlaying = true;
      _desiredPlaying = true;
      _showControls = false;
    });
    _applyDesiredPlayState();
  }

  void _handlePlaybackSurfaceTap() {
    final ctrl = _ctrl;
    if (_isApplyingSeek || ctrl == null || !ctrl.value.isInitialized) return;

    final isPlaying = _desiredPlaying ?? ctrl.value.isPlaying;
    if (isPlaying) {
      _pauseAndShowPlayButton();
    } else {
      _resumeFromPlayButton();
    }
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
          _updateState(() {
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

  void _handleProgressPlayingChanged(bool playing) {
    if (!mounted) return;
    _updateState(() {
      _isPlaying = playing;
      _desiredPlaying = null;
    });
  }

  Future<void> _toggleFavorite() async {
    final item = _items[_index];
    final newVal = !item.isFavorite;
    _updateState(() => _items[_index] = item.copyWith(isFavorite: newVal));
    try {
      await EmbyService().setFavorite(item.id, favorite: newVal);
    } catch (_) {
      _updateState(
        () => _items[_index] = item.copyWith(isFavorite: item.isFavorite),
      );
    }
  }
}
