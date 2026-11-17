// i18n:data — station errors are translated by playback controls.
part of 'app_state.dart';

/// Recommendation refills and rolling history. Ordinary playlists retain their
/// full contents; only an indefinitely growing station discards played entries.
extension _AppStateStation on AppState {
  Future<bool> _ensureStationBuffer({bool force = false}) {
    final session = _station;
    if (session == null || _presentationDisposed) return Future.value(false);
    if (session.pending case final pending?) return pending;
    if (!force && _queue.length - _queueIndex >= 6) return Future.value(false);
    return session.refill(() => _refillStation(session));
  }

  Future<bool> _refillStation(StationSession session) async {
    try {
      List<Track> lastLoaded = const [];
      for (var attempt = 0; attempt < 2; attempt++) {
        final loaded = await session.nextBatch();
        if (_station != session || _presentationDisposed) return false;
        lastLoaded = loaded;
        final additions = session.fresh(loaded);
        if (additions.isEmpty) continue;
        _appendStationTracks(additions);
        return true;
      }
      // A finite radio may recycle older recommendations once its fresh batch
      // is exhausted. Shuffle only the bounded selection, not a whole catalog.
      final fallback =
          lastLoaded.where((track) => track.id != current?.id).take(20).toList()
            ..shuffle();
      if (fallback.isNotEmpty && _station == session) {
        _appendStationTracks(fallback);
        return true;
      }
    } catch (_) {
      // Keep the playable buffer. A later tail request can try again.
    }
    return false;
  }

  void _appendStationTracks(List<Track> additions) {
    final overflow =
        _queue.length + additions.length - StationSession.maximumQueueTracks;
    // A shuffled successor can point into older history. Its decoder still owns
    // that song, so retain its entry alongside both sides of a live mix.
    final earliest = math.min(
      math.min(_queueIndex, _mixFromIndex ?? _queueIndex),
      _queuedNextIndex ?? _queueIndex,
    );
    final removed = math.min(math.max(overflow, 0), earliest);
    if (removed > 0) {
      _queue.removeRange(0, removed);
      _queueIndex -= removed;
      if (_mixFromIndex case final index?) _mixFromIndex = index - removed;
      if (_queuedNextIndex case final index?) {
        _queuedNextIndex = index - removed;
      }
      // A pending resolve captured the old numeric indexes; discard its result.
      ++_prefetchGeneration;
      _shuffleOrder.reset();
    }
    final available = StationSession.maximumQueueTracks - _queue.length;
    _queue.addAll(additions.take(available));
    _markQueueChanged();
    unawaited(_saveQueue());
    notifyListeners();
    if (_realActive && !_engineHoldsSuccessor) unawaited(_prefetchNext());
  }

  Future<void> _advanceStationFromTail() async {
    final session = _station;
    final track = current;
    final generation = _generation;
    await _ensureStationBuffer(force: true);
    if (_station != session ||
        _presentationDisposed ||
        generation != _generation ||
        current != track) {
      return;
    }
    if (_queueIndex + 1 < _queue.length) {
      final next = _queueIndex + 1;
      _finishListening(manualTarget: _queue[next]);
      _moveTo(next, direction: 1);
      return;
    }
    playbackError = '暂时没有更多歌曲，请稍后重试。';
    notifyListeners();
  }

  Future<void> _continueStationAfterEnd() async {
    final session = _station;
    final track = current;
    final generation = _generation;
    bool stillCurrent() =>
        _station == session &&
        !_presentationDisposed &&
        _generation == generation &&
        current == track &&
        _playing;
    await _ensureStationBuffer(force: true);
    if (!stillCurrent()) return;
    if (_queueIndex + 1 >= _queue.length) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!stillCurrent()) return;
      await _ensureStationBuffer(force: true);
    }
    if (!stillCurrent()) return;
    if (_queueIndex + 1 < _queue.length) {
      _moveTo(_queueIndex + 1, direction: 1);
      return;
    }
    _playing = false;
    _ticker?.cancel();
    await audioEngine?.stop();
    if (_presentationDisposed ||
        _station != session ||
        _generation != generation ||
        current != track ||
        _playing) {
      return;
    }
    playbackError = '暂时没有更多歌曲，请稍后重试。';
    notifyListeners();
  }
}
