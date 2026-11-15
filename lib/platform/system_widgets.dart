import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'widget_artwork_stub.dart'
    if (dart.library.io) 'widget_artwork_io.dart'
    as artwork;

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
    } catch (_) {
      // Widgets are optional and must never interrupt audio or persistence.
    }
  }

  static Future<void> _send(Map<String, Object?> data) =>
      _channel.invokeMethod<void>('updateRecentPlayback', data);

  void dispose() {
    _disposed = true;
    _pending = null;
    _latest = null;
    _pendingArtwork = null;
    _artworkGeneration++;
    _artwork = null;
  }
}
