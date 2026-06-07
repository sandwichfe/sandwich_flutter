// Emby 播放页播放列表逻辑：处理加载更多、顺序/随机播放，以及切换视频。
part of 'emby_stream_page.dart';

extension _EmbyStreamPlaylist on _EmbyStreamPageState {
  bool get _hasMoreItems {
    final totalCount = _totalCount;
    if (totalCount != null) return _items.length < totalCount;
    return widget.onLoadMore != null;
  }

  bool get _canMoveForward =>
      _playbackMode == _PlaybackMode.random ||
      _index < _items.length - 1 ||
      _hasMoreItems;

  String get _countLabel {
    final totalCount = _totalCount;
    if (totalCount != null && totalCount > _items.length) {
      return '${_index + 1} / ${_items.length} / $totalCount';
    }
    return '${_index + 1} / ${_items.length}';
  }

  Future<bool> _loadMoreItems() async {
    final loader = widget.onLoadMore;
    if (_isLoadingMoreItems || loader == null || !_hasMoreItems) return false;

    _updateState(() => _isLoadingMoreItems = true);
    try {
      final result = await loader(_items.length);
      if (!mounted) return false;

      final knownIds = _items.map((e) => e.id).toSet();
      final newItems =
          result.items.where((item) => knownIds.add(item.id)).toList();
      _updateState(() {
        _items.addAll(newItems);
        _totalCount = result.total;
      });
      return newItems.isNotEmpty;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
      return false;
    } finally {
      if (mounted) _updateState(() => _isLoadingMoreItems = false);
    }
  }

  Future<void> _loadAllItems() async {
    while (mounted && _hasMoreItems) {
      final loaded = await _loadMoreItems();
      if (!loaded) return;
    }
  }

  void _resetRandomQueue() {
    _randomQueue
      ..clear()
      ..addAll(
        List<int>.generate(_items.length, (i) => i).where((i) => i != _index),
      )
      ..shuffle(_random);
  }

  Future<int?> _nextIndex() async {
    if (_playbackMode == _PlaybackMode.sequential) {
      if (_index < _items.length - 1) return _index + 1;
      final loaded = await _loadMoreItems();
      if (loaded && _index < _items.length - 1) return _index + 1;
      return null;
    }

    await _loadAllItems();
    if (_items.length <= 1) return null;
    if (_randomQueue.isEmpty) _resetRandomQueue();
    if (_randomQueue.isEmpty) return null;
    _randomHistory.add(_index);
    return _randomQueue.removeLast();
  }

  Future<int?> _previousIndex() async {
    if (_playbackMode == _PlaybackMode.sequential) {
      return _index > 0 ? _index - 1 : null;
    }

    if (_randomHistory.isNotEmpty) return _randomHistory.removeLast();
    await _loadAllItems();
    if (_items.length <= 1) return null;
    final candidates =
        List<int>.generate(
          _items.length,
          (i) => i,
        ).where((i) => i != _index).toList();
    return candidates[_random.nextInt(candidates.length)];
  }

  Future<void> _switchToNext({double? exitOffset}) async {
    final targetIndex = await _nextIndex();
    if (targetIndex != null) {
      await _switchTo(targetIndex, exitOffset: exitOffset);
    } else if (exitOffset == null) {
      await _animateDragTo(0);
    }
  }

  Future<void> _switchToPrevious({double? exitOffset}) async {
    final targetIndex = await _previousIndex();
    if (targetIndex != null) {
      await _switchTo(targetIndex, exitOffset: exitOffset);
    } else if (exitOffset == null) {
      await _animateDragTo(0);
    }
  }

  Future<void> _restorePlaybackMode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString(embyPlaybackModeStorageKey);
    if (!mounted || savedMode != embyRandomPlaybackModeValue) {
      return;
    }

    _updateState(() {
      _playbackMode = _PlaybackMode.random;
      _randomQueue.clear();
      _randomHistory.clear();
    });
    if (_hasMoreItems) {
      _showToast('\u6b63\u5728\u52a0\u8f7d\u89c6\u9891\u5217\u8868...');
    }
    await _loadAllItems();
    if (mounted) _resetRandomQueue();
  }

  Future<void> _togglePlaybackMode() async {
    final nextMode =
        _playbackMode == _PlaybackMode.sequential
            ? _PlaybackMode.random
            : _PlaybackMode.sequential;

    _updateState(() {
      _playbackMode = nextMode;
      _randomQueue.clear();
      _randomHistory.clear();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      embyPlaybackModeStorageKey,
      nextMode == _PlaybackMode.random
          ? embyRandomPlaybackModeValue
          : 'sequential',
    );
    if (mounted) _showPlaybackModeToast(nextMode);

    if (nextMode == _PlaybackMode.random) {
      if (mounted && _hasMoreItems) {
        _showToast('\u6b63\u5728\u52a0\u8f7d\u89c6\u9891\u5217\u8868...');
      }
      await _loadAllItems();
      if (mounted) _resetRandomQueue();
    }
  }

  void _showPlaybackModeToast(_PlaybackMode mode) {
    final label =
        mode == _PlaybackMode.random
            ? '\u5df2\u5207\u6362\u5230\u968f\u673a\u64ad\u653e'
            : '\u5df2\u5207\u6362\u5230\u987a\u5e8f\u64ad\u653e';

    _showToast(label);
  }

  Future<void> _switchTo(int targetIndex, {double? exitOffset}) async {
    if (_isSwitchingVideo ||
        targetIndex == _index ||
        targetIndex < 0 ||
        targetIndex >= _items.length) {
      return;
    }

    _updateState(() => _isSwitchingVideo = true);
    if (exitOffset != null) {
      await _animateDragTo(
        exitOffset,
        duration: _EmbyStreamPageState._switchExitDuration,
        curve: Curves.easeInOutCubic,
      );
    }
    if (!mounted) return;

    _updateState(() {
      _index = targetIndex;
      _rawDragOffsetY = 0;
      _dragOffsetY = 0;
    });
    await _play(targetIndex);
    if (mounted) _updateState(() => _isSwitchingVideo = false);
  }
}
