import 'dart:async';
import 'dart:collection';
import 'dart:convert';

/// One persistent stream listener owns each socket. Pending data stays bounded
/// and a timed-out receive never cancels the underlying WebSocket subscription.
class PluginSocketInbox {
  final Queue<(Object, int)> _messages = Queue();
  Completer<Object?>? _pending;
  int _bytes = 0;
  bool _closed = false;
  bool get drained => _closed && _messages.isEmpty;

  bool add(Object data) {
    if (_closed) return false;
    final bytes = data is String
        ? utf8.encode(data).length
        : data is List
        ? data.length
        : 0;
    if (bytes > 1024 * 1024 ||
        _bytes + bytes > 4 * 1024 * 1024 ||
        _messages.length >= 128) {
      return false;
    }
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      pending.complete(data);
    } else {
      _messages.add((data, bytes));
      _bytes += bytes;
    }
    return true;
  }

  Future<Object?> receive(int timeoutMs) async {
    if (_messages.isNotEmpty) {
      final entry = _messages.removeFirst();
      _bytes -= entry.$2;
      return entry.$1;
    }
    if (_closed || timeoutMs <= 0) return null;
    if (_pending != null) throw StateError('A receive is already pending');
    final pending = _pending = Completer<Object?>();
    final timer = Timer(Duration(milliseconds: timeoutMs.clamp(0, 30000)), () {
      if (identical(_pending, pending)) {
        _pending = null;
        pending.complete(null);
      }
    });
    try {
      return await pending.future;
    } finally {
      timer.cancel();
    }
  }

  void close({bool discard = false}) {
    _closed = true;
    if (discard) {
      _messages.clear();
      _bytes = 0;
    }
    _pending?.complete(null);
    _pending = null;
  }
}

int pluginSocketTimeout(Map<String, dynamic> spec) =>
    (spec['timeoutMs'] as num?)?.toInt().clamp(0, 30000) ?? 30000;

Object pluginSocketData(Object? data) {
  if (data == null) return '';
  if (data is String && utf8.encode(data).length <= 1024 * 1024) return data;
  if (data is List &&
      data.length <= 1024 * 1024 &&
      data.every((v) => v is int && v >= 0 && v <= 255)) {
    return List<int>.from(data);
  }
  throw const FormatException(
    'WebSocket data must be text or bytes, at most 1 MB',
  );
}
