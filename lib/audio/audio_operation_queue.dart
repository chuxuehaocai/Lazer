import 'dart:async';
import 'dart:collection';

/// Serializes decoder mutations with bounded waiting work. Keyed operations
/// replace only work that has not started; active work always owns its lifetime.
class AudioOperationQueue {
  AudioOperationQueue({this.maximumPending = 128}) : assert(maximumPending > 0);

  final int maximumPending;
  final Queue<_PendingAudioOperation> _waiting = Queue();
  final Map<Object, _PendingAudioOperation> _keyed = {};
  Completer<void>? _idle;
  bool _draining = false;

  Future<void> get idle => _idle?.future ?? Future<void>.value();

  /// Drops waiting work while the active operation retains its resources.
  void cancelPending() {
    final retired = _waiting.toList(growable: false);
    _waiting.clear();
    _keyed.clear();
    for (final task in retired) {
      task.supersede();
    }
  }

  Future<T> run<T>(
    Future<T> Function() operation, {
    Object? key,
    T Function()? onSuperseded,
    bool essential = false,
  }) {
    if (key != null) {
      final previous = _keyed.remove(key);
      if (previous != null) {
        _waiting.remove(previous);
        previous.supersede();
      }
    }
    if (_waiting.length >= maximumPending) {
      if (!essential) {
        return Future<T>.error(StateError('the audio operation queue is full'));
      }
      // A stop must be accepted even during a burst of controls. Retire one
      // waiting item, so essential operations share the same fixed budget.
      final retired = _waiting.removeFirst();
      _removeKey(retired);
      retired.supersede();
    }
    final task = _AudioOperation<T>(operation, key, onSuperseded);
    _waiting.add(task);
    if (key != null) _keyed[key] = task;
    _idle ??= Completer<void>();
    if (!_draining) {
      _draining = true;
      scheduleMicrotask(_drain);
    }
    return task.future;
  }

  void _removeKey(_PendingAudioOperation task) {
    final key = task.key;
    if (key != null && identical(_keyed[key], task)) _keyed.remove(key);
  }

  Future<void> _drain() async {
    while (_waiting.isNotEmpty) {
      final task = _waiting.removeFirst();
      _removeKey(task);
      await task.execute();
    }
    _draining = false;
    final finished = _idle;
    _idle = null;
    finished?.complete();
  }
}

abstract class _PendingAudioOperation {
  Object? get key;
  Future<void> execute();
  void supersede();
}

class _AudioOperation<T> implements _PendingAudioOperation {
  _AudioOperation(this._operation, this.key, this._onSuperseded);

  Future<T> Function()? _operation;
  @override
  final Object? key;
  T Function()? _onSuperseded;
  final _result = Completer<T>();
  Future<T> get future => _result.future;

  @override
  Future<void> execute() async {
    final operation = _operation;
    _operation = null;
    _onSuperseded = null;
    try {
      _result.complete(await operation!());
    } catch (error, stack) {
      _result.completeError(error, stack);
    }
  }

  @override
  void supersede() {
    _operation = null;
    final complete = _onSuperseded;
    _onSuperseded = null;
    if (complete == null) {
      _result.completeError(StateError('the audio operation was superseded'));
    } else {
      try {
        _result.complete(complete());
      } catch (error, stack) {
        _result.completeError(error, stack);
      }
    }
  }
}
