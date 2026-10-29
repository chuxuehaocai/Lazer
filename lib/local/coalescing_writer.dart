/// Serializes writes and folds overlapping requests into the latest snapshot.
/// All callers wait until writes requested during their batch have completed.
class CoalescingWriter {
  CoalescingWriter(this._write);

  final Future<void> Function() _write;
  Future<void>? _active;
  bool _dirty = false;

  Future<void> request() {
    _dirty = true;
    return _active ??= Future<void>.microtask(_drain);
  }

  Future<void> _drain() async {
    try {
      do {
        _dirty = false;
        await _write();
      } while (_dirty);
    } finally {
      _active = null;
    }
  }
}
