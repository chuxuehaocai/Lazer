import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';

const String playbackQueueKey = 'lazer_playback_queue_v1';

typedef QueueEncoder = Future<String> Function(List<Track> tracks);
typedef QueueWriter = Future<void> Function(String value);
typedef QueueReader = Future<String?> Function();
typedef QueueDecoder = Future<PlaybackQueueSnapshot?> Function(String value);

class PlaybackQueueSnapshot {
  const PlaybackQueueSnapshot(this.tracks, this.index);
  final List<Track> tracks;
  final int index;
}

/// Serializes queue writes and reuses the track payload when only the index
/// changes. The latest request always follows any write already in flight.
class PlaybackQueueStore {
  PlaybackQueueStore({
    QueueEncoder? encode,
    QueueWriter? write,
    QueueReader? read,
    QueueDecoder? decode,
  }) : _encode = encode ?? _encodeOffThread,
       _write = write ?? _writePreferences,
       _read = read ?? _readPreferences,
       _decode = decode ?? _decodeOffThread;

  final QueueEncoder _encode;
  final QueueWriter _write;
  final QueueReader _read;
  final QueueDecoder _decode;
  List<Track> _tracks = const [];
  int? _revision;
  int? _encodedRevision;
  String? _encodedTracks;
  int _index = 0;
  int _request = 0;
  Future<void>? _pending;

  Future<PlaybackQueueSnapshot?> load() async {
    try {
      final String? raw = await _read();
      return raw == null ? null : await _decode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(List<Track> tracks, int index, int revision) {
    if (_revision != revision) {
      // A station can append in place while an isolate is encoding.
      _tracks = List<Track>.of(tracks);
      _revision = revision;
    }
    _index = index;
    _request++;
    return _pending ??= _flush();
  }

  Future<void> _flush() async {
    try {
      while (true) {
        final int requested = _request;
        final int? revision = _revision;
        try {
          if (_encodedRevision != revision) {
            final String encoded = await _encode(_tracks);
            if (revision != _revision) continue;
            _encodedTracks = encoded;
            _encodedRevision = revision;
          }
          // The index may have changed while the payload was being encoded.
          final int writeRequest = _request;
          final int index = _index;
          await _write('{"index":$index,"tracks":$_encodedTracks}');
          if (writeRequest == _request) return;
        } catch (_) {
          // Persistence is best-effort. A later request retries; do not lose a
          // request that arrived while an earlier write was failing.
          if (requested == _request) return;
        }
      }
    } finally {
      _pending = null;
    }
  }
}

Future<String> _encodeOffThread(List<Track> tracks) => tracks.length < 128
    ? Future<String>.value(_encodeTracks(tracks))
    : compute(_encodeTracks, tracks, debugLabel: 'playback-queue-encode');

String _encodeTracks(List<Track> tracks) => jsonEncode([
  for (final track in tracks)
    {
      'id': track.id,
      'title': track.title,
      'translatedTitle': track.translatedTitle,
      'artist': track.artist,
      'artists': [for (final artist in track.artists) artist.toJson()],
      'album': track.album,
      'albumId': track.albumId,
      'durationMs': track.duration.inMilliseconds,
      'coverSeed': track.coverSeed,
      'accent': track.accent,
      'coverUrl': track.coverUrl,
    },
]);

Future<void> _writePreferences(String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(playbackQueueKey, value);
}

Future<String?> _readPreferences() async =>
    (await SharedPreferences.getInstance()).getString(playbackQueueKey);

Future<PlaybackQueueSnapshot?> _decodeOffThread(String raw) =>
    raw.length < 65536
    ? Future<PlaybackQueueSnapshot?>.value(_decodeQueue(raw))
    : compute(_decodeQueue, raw, debugLabel: 'playback-queue-decode');

PlaybackQueueSnapshot? _decodeQueue(String raw) {
  final dynamic json = jsonDecode(raw);
  if (json is! Map<String, dynamic> || json['tracks'] is! List) return null;
  final tracks = <Track>[];
  for (final item in json['tracks'] as List) {
    if (item is! Map<String, dynamic>) continue;
    final id = item['id'] as String? ?? '';
    if (int.tryParse(id) == null) continue;
    tracks.add(
      Track(
        id: id,
        title: item['title'] as String? ?? '',
        artist: item['artist'] as String? ?? '',
        artists: ArtistRef.list(item['artists']),
        album: item['album'] as String? ?? '',
        duration: Duration(
          milliseconds: (item['durationMs'] as num?)?.toInt() ?? 0,
        ),
        coverSeed: (item['coverSeed'] as num?)?.toInt() ?? 0,
        accent: (item['accent'] as num?)?.toInt() ?? 0,
        albumId: (item['albumId'] as num?)?.toInt() ?? 0,
        coverUrl: item['coverUrl'] as String?,
        translatedTitle: item['translatedTitle'] as String?,
      ),
    );
  }
  final int index = ((json['index'] as num?)?.toInt() ?? 0).clamp(
    0,
    tracks.isEmpty ? 0 : tracks.length - 1,
  );
  return PlaybackQueueSnapshot(tracks, index);
}
