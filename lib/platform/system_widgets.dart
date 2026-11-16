import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'widget_artwork_stub.dart'
    if (dart.library.io) 'widget_artwork_io.dart'
    as artwork;

/// Why the last widget publication produced no visible widget.
///
/// A widget is optional, so its failures never interrupt playback, but an empty
/// home-screen card with no explanation is indistinguishable from a broken
/// install. This is what the app is allowed to say about it.
enum SystemWidgetStatus {
  /// Nothing has been published yet this launch.
  idle,

  /// The snapshot reached the native store and the widget was asked to reload.
  published,

  /// The snapshot was already current.
  unchanged,

  /// The platform refused the snapshot; [SystemWidgetsBridge.lastReason] says why.
  failed,
}

/// What the native side reports after trying to store a snapshot.
///
/// Mirrors `WidgetWriteStatus` in `ios/Runner/AppDelegate.swift`. The two
/// successes mean "nothing to fix"; every other value names a reason the home
/// screen can stay empty, and [systemWidgetWriteFailure] turns it into text.
const String systemWidgetStatusUpdated = 'updated';
const String systemWidgetStatusUnchanged = 'unchanged';
const String systemWidgetStatusAppGroupUnavailable = 'appGroupUnavailable';
const String systemWidgetStatusWriteFailed = 'writeFailed';

/// The reason [status] names, or null when the write succeeded.
///
/// Unknown values are reported as a failure with the raw name rather than
/// ignored: a platform status this build does not know about is exactly the case
/// where a silently empty widget would go unnoticed.
String? systemWidgetWriteFailure(String status) => switch (status) {
  systemWidgetStatusUpdated || systemWidgetStatusUnchanged => null,
  systemWidgetStatusAppGroupUnavailable =>
    '小部件无法读取共享容器：当前安装包缺少 App Groups 权限，重新签名或重装后可用',
  systemWidgetStatusWriteFailed => '小部件快照写入失败',
  _ => '小部件存储返回了未知状态：$status',
};

/// Publishes one bounded recent-playback snapshot, never playback ticks.
/// Native widgets persist it so they remain useful while the app is closed.
class SystemWidgetsBridge {
  SystemWidgetsBridge({
    Future<void> Function(Map<String, Object?>)? publish,
    Future<Uint8List?> Function(String)? loadArtwork,
  }) : _publish = publish ?? _send,
       _loadArtwork = loadArtwork ?? artwork.loadWidgetArtwork,
       _enabled =
           publish != null ||
           (!kIsWeb &&
               (defaultTargetPlatform == TargetPlatform.android ||
                   defaultTargetPlatform == TargetPlatform.iOS));

  static const _channel = MethodChannel('dev.naominet.lazer/system_widgets');
  final Future<void> Function(Map<String, Object?>) _publish;
  final Future<Uint8List?> Function(String) _loadArtwork;
  final bool _enabled;
  Map<String, Object?>? _pending;
  Map<String, Object?>? _latest;
  Future<void>? _running;
  Future<void>? _artworkRunning;
  (String, int)? _pendingArtwork;
  int _artworkGeneration = 0;
  String? _requestedKey, _artworkSource;
  Uint8List? _artwork;
  bool _disposed = false;

  SystemWidgetStatus _status = SystemWidgetStatus.idle;

  /// The status of the last publication, for diagnostics.
  SystemWidgetStatus get status => _status;

  /// Why the last publication failed, verbatim from the platform.
  ///
  /// On iOS this is the widget write status (`appGroupUnavailable`,
  /// `writeFailed`), which is the only way a build without the App Groups
  /// entitlement can be told apart from one that has simply never played a song.
  String? get lastReason => _lastReason;
  String? _lastReason;

  Future<void> update({
    required Track? track,
    required bool playing,
    required String language,
  }) {
    if (!_enabled || _disposed) return Future<void>.value();
    final data = <String, Object?>{
      'trackId': track?.id ?? '',
      'title': track?.title ?? '',
      'artist': track?.artist ?? '',
      'album': track?.album ?? '',
      'hasTrack': track != null,
      'playing': track != null && playing,
      'language': language,
      'coverSource': track?.coverUrl ?? '',
    };
    final key = jsonEncode(data);
    if (_requestedKey == key) return _running ?? Future<void>.value();
    _requestedKey = key;
    final source = data.remove('coverSource') as String;
    if (source != _artworkSource) {
      _artworkSource = source;
      _artwork = null;
      final generation = ++_artworkGeneration;
      _pendingArtwork = source.isEmpty ? null : (source, generation);
    }
    _latest = data;
    data['artwork'] = _artwork;
    _pending = data;
    final published = _running ??= _drain();
    if (_pendingArtwork != null) {
      _artworkRunning ??= _drainArtwork();
    }
    return published;
  }

  Future<void> _drain() async {
    try {
      while (!_disposed && _pending != null) {
        final data = _pending!;
        _pending = null;
        // Publish the title immediately; a slow cover must not leave the
        // previous song on the home screen or block playback.
        await _safePublish(data);
      }
    } finally {
      _running = null;
    }
  }

  Future<void> _drainArtwork() async {
    try {
      // Covers have a separate, bounded lane: a pending download must not
      // delay the next title, while rapid skips need only the newest cover.
      while (!_disposed && _pendingArtwork != null) {
        final (source, generation) = _pendingArtwork!;
        _pendingArtwork = null;
        Uint8List? bytes;
        try {
          bytes = await Future<Uint8List?>.sync(() => _loadArtwork(source));
        } catch (_) {
          bytes = null;
        }
        if (_disposed || generation != _artworkGeneration) continue;
        _artwork = bytes;
        if (bytes == null) continue;
        _pending = {..._latest!, 'artwork': bytes};
        _running ??= _drain();
      }
    } finally {
      _artworkRunning = null;
    }
  }

  Future<void> _safePublish(Map<String, Object?> data) async {
    try {
      await _publish(Map<String, Object?>.of(data));
      _status = SystemWidgetStatus.published;
      _lastReason = null;
    } catch (error) {
      // Widgets are optional and must never interrupt audio or persistence, but
      // a widget that can never be written is a different thing from a widget
      // with nothing to show. Keep the reason so the settings page and the
      // exported log can name it.
      _status = SystemWidgetStatus.failed;
      _lastReason = '$error';
    }
  }

  /// Sends one snapshot and turns the platform's write status into a failure.
  ///
  /// iOS answers with [SystemWidgetWriteStatus] names instead of throwing, so a
  /// missing App Group entitlement is reported rather than silently swallowed.
  static Future<void> _send(Map<String, Object?> data) async {
    final Object? status = await _channel.invokeMethod<Object?>(
      'updateRecentPlayback',
      data,
    );
    if (status is String) {
      final String? reason = systemWidgetWriteFailure(status);
      if (reason != null) {
        throw StateError(reason);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    _latest = null;
    _pendingArtwork = null;
    _artworkGeneration++;
    _artwork = null;
  }
}
