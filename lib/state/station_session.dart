import 'dart:async';
import 'dart:collection';

import '../data/models.dart';

/// Disposable recommendation state; this is separate from a user's playlist.
/// Old sessions own their pending Future, so a late completion cannot unlock or
/// append to a replacement station using the same loader function.
class StationSession {
  StationSession(this.loadMore, Iterable<Track> initial) {
    for (final track in initial) {
      _remember(track.id);
    }
  }

  static const maximumQueueTracks = 256;
  static const maximumSeenTracks = 1024;
  static const maximumBatchTracks = 30;

  final Future<List<Track>> Function() loadMore;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  Future<bool>? _pending;
  Completer<List<Track>>? _batch;
  Future<List<Track>>? _batchFuture;
  Future<List<Track>>? _request;
  Timer? _batchGuard;
  bool _closed = false;

  Future<bool>? get pending => _pending;
  bool get loading => _pending != null;

  Future<bool> refill(Future<bool> Function() action) {
    if (_closed) return Future.value(false);
    return _pending ??= Future<bool>.microtask(() async {
      try {
        return await action();
      } finally {
        _pending = null;
      }
    });
  }

  Future<List<Track>> nextBatch() {
    if (_closed) return Future.error(StateError('Station closed'));
    if (_batchFuture case final current?) return current;
    final result = Completer<List<Track>>();
    _batch = result;
    _batchGuard = Timer(const Duration(seconds: 20), () {
      if (!result.isCompleted) {
        result.completeError(TimeoutException('Station refill timed out'));
      }
    });
    _batchFuture = result.future.whenComplete(() {
      if (identical(_batch, result)) {
        _batchGuard?.cancel();
        _batchGuard = null;
        _batch = null;
        _batchFuture = null;
      }
    });
    // A timeout ends only the current UI wait. Attach once to an outstanding
    // provider request and deliver to whichever wait is current when it settles.
    // Per-retry .then callbacks would otherwise retain every expired completer.
    if (_request == null) {
      final request = Future<List<Track>>.sync(loadMore);
      _request = request;
      unawaited(
        request.then<void>(
          (value) {
            if (identical(_request, request)) _request = null;
            final waiting = _batch;
            if (waiting != null && !waiting.isCompleted) {
              waiting.complete(value);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (identical(_request, request)) _request = null;
            final waiting = _batch;
            if (waiting != null && !waiting.isCompleted) {
              waiting.completeError(error, stack);
            }
          },
        ),
      );
    }
    return _batchFuture!;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _batchGuard?.cancel();
    _batchGuard = null;
    final batch = _batch;
    if (batch != null && !batch.isCompleted) {
      batch.completeError(StateError('Station closed'));
    }
    _seen.clear();
  }

  List<Track> fresh(Iterable<Track> batch) {
    final result = <Track>[];
    for (final track in batch.take(maximumSeenTracks * 2)) {
      if (_seen.contains(track.id)) continue;
      _remember(track.id);
      result.add(track);
      if (result.length == maximumBatchTracks) break;
    }
    return result;
  }

  void _remember(String id) {
    _seen.add(id);
    if (_seen.length > maximumSeenTracks) _seen.remove(_seen.first);
  }
}
