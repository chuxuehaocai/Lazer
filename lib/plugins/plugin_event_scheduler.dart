import 'dart:async';

/// Bounded wakeups for plugins that serve requests while playback is idle.
/// A slow VM never accumulates timer events: each timer has at most one call
/// in flight (including time spent waiting in the VM's serial queue).
class PluginEventScheduler {
  PluginEventScheduler(this.dispatch);

  final Future<Object?> Function(String, Map<String, dynamic>) dispatch;
  final Map<String, _ScheduledEvent> _events = {};
  // Cancellation/replacement cannot refund a call still queued in the VM.
  // Keep these slots independent of the active timer map.
  final Set<String> _pendingIds = {};

  Object configure(Map<String, dynamic> spec) {
    final operation = spec['operation'] ?? 'set';
    if (operation == 'list') return _events.keys.toList();
    final id = spec['id'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(id)) {
      throw const FormatException('Invalid plugin timer ID');
    }
    if (operation == 'cancel') {
      _events.remove(id)?.timer.cancel();
      return true;
    }
    if (operation != 'set') {
      throw const FormatException('Unknown plugin timer operation');
    }
    final interval = spec['intervalMs'];
    if (interval is! num ||
        !interval.isFinite ||
        interval != interval.toInt() ||
        interval < 100 ||
        interval > 60000) {
      throw const FormatException(
        'Plugin timer interval must be 100..60000 ms',
      );
    }
    if (!_events.containsKey(id) && _events.length >= 4) {
      throw const FormatException('Plugin timer limit reached');
    }
    _events.remove(id)?.timer.cancel();
    final event = _ScheduledEvent();
    _events[id] = event;
    event.timer = Timer.periodic(Duration(milliseconds: interval.toInt()), (_) {
      if (_pendingIds.contains(id) ||
          _pendingIds.length >= 4 ||
          !identical(_events[id], event)) {
        return;
      }
      _pendingIds.add(id);
      unawaited(_dispatch(id));
    });
    return true;
  }

  Future<void> _dispatch(String id) async {
    try {
      await dispatch('timer', {'id': id});
    } catch (_) {
      // Runtime failures already have their own diagnostics. A failed tick
      // cannot escape into the host zone or keep an abandoned VM alive.
    } finally {
      _pendingIds.remove(id);
    }
  }

  void cancelAll() {
    for (final event in _events.values) {
      event.timer.cancel();
    }
    _events.clear();
  }
}

class _ScheduledEvent {
  late final Timer timer;
}
