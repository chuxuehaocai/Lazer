import 'dart:async';

/// A room update represents current state, so only its newest pending value
/// matters. Slow plugins retain at most one running and one pending operation.
class LatestRoomRequest {
  Future<void> Function()? _pending;
  bool _running = false;
  bool _closed = false;

  bool get hasPending => _pending != null;

  void schedule(Future<void> Function() operation) {
    if (_closed) return;
    _pending = operation;
    if (!_running) unawaited(_drain());
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (!_closed && _pending != null) {
        final operation = _pending!;
        _pending = null;
        try {
          await operation();
        } catch (_) {
          // Polling retries transient room failures; do not strand newer work.
        }
      }
    } finally {
      _running = false;
    }
  }

  void cancelPending() => _pending = null;

  void dispose() {
    _closed = true;
    cancelPending();
  }
}
