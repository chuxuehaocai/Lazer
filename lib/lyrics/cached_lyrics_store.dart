import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../data/models.dart';
import '../gateway/music_models.dart';
import '../storage/app_storage.dart';

/// Durable lyrics are independent of the HTTP cache. The file alias lets a
/// scanned download retain word timings and translations under a local ID.
class CachedLyricsStore {
  CachedLyricsStore({Future<Directory> Function()? supportDirectory})
    : _support = supportDirectory ?? appSupportDirectory;
  final Future<Directory> Function() _support;
  final Map<String, Future<void>> _writes = {};

  /// How long a "no lyrics" verdict stays authoritative.
  ///
  /// That verdict is an inference, not a fact the service stated: a provider
  /// without the capability to decode its own lyric format, a transient
  /// service gap or a plugin upgrade all produce an empty reply. Caching it
  /// forever left the song stuck on "instrumental" with no way back, so the
  /// entry expires and the provider gets asked again.
  static const Duration pureMusicTtl = Duration(hours: 24);

  List<String> _keys(Track track, String? audioPath) {
    final keys = <String>[if (track.id.isNotEmpty) 'song:${track.id}'];
    final path = audioPath ?? track.localPath;
    if (path != null) {
      final value = File(path).absolute.uri.normalizePath().toString();
      keys.add('file:${Platform.isWindows ? value.toLowerCase() : value}');
    }
    return keys;
  }

  Future<File> _file(String key, {bool create = false}) async {
    final directory = Directory(
      '${(await _support()).path}${Platform.pathSeparator}cached_lyrics',
    );
    if (create) await directory.create(recursive: true);
    return File(
      '${directory.path}${Platform.pathSeparator}${sha256.convert(utf8.encode(key))}.json',
    );
  }

  Future<GatewayLyrics?> read(Track track, {String? audioPath}) async {
    for (final key in _keys(track, audioPath)) {
      try {
        final pending = _writes[key];
        if (pending != null) await pending;
        final file = await _file(key);
        if (!await file.exists()) continue;
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final payload = GatewayLyrics(
          lrc: data['lrc'] as String?,
          yrc: data['yrc'] as String?,
          tlyric: data['tlyric'] as String?,
          ytlrc: data['ytlrc'] as String?,
          rlyric: data['rlyric'] as String?,
          yromalrc: data['yromalrc'] as String?,
          ttml: data['ttml'] as String?,
          pureMusic: data['pureMusic'] == true,
        );
        if (payload.hasTimedLyric) return payload;
        if (!payload.pureMusic) continue;
        // A stored "no lyrics" verdict is an inference, so it expires. Rows
        // written before `savedAt` existed are treated as expired too: that is
        // exactly the generation this TTL is meant to release.
        final savedAt = DateTime.tryParse(data['savedAt'] as String? ?? '');
        if (savedAt == null) continue;
        if (DateTime.now().toUtc().difference(savedAt) > pureMusicTtl) continue;
        return payload;
      } catch (_) {
        // Another identity or the provider can still supply the lyrics.
      }
    }
    return null;
  }

  Future<void> save(
    Track track,
    GatewayLyrics payload, {
    String? audioPath,
  }) async {
    if (!payload.hasTimedLyric && !payload.pureMusic) return;
    final data = jsonEncode({
      'version': 1,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'lrc': payload.lrc,
      'yrc': payload.yrc,
      'tlyric': payload.tlyric,
      'ytlrc': payload.ytlrc,
      'rlyric': payload.rlyric,
      'yromalrc': payload.yromalrc,
      'ttml': payload.ttml,
      'pureMusic': payload.pureMusic,
    });
    await Future.wait(
      _keys(track, audioPath).map((key) async {
        final prior = _writes[key] ?? Future<void>.value();
        final writing = prior.then((_) async {
          try {
            final file = await _file(key, create: true);
            final temporary = File('${file.path}.tmp');
            await temporary.writeAsString(data, flush: true);
            await temporary.rename(file.path);
          } catch (_) {
            // Audio remains playable when lyric storage is unavailable.
          }
        });
        _writes[key] = writing;
        try {
          await writing;
        } finally {
          if (identical(_writes[key], writing)) _writes.remove(key);
        }
      }),
    );
  }

  /// Reports how many lyric files are currently cached on disk.
  Future<int> count() async {
    try {
      final directory = Directory(
        '${(await _support()).path}${Platform.pathSeparator}cached_lyrics',
      );
      if (!await directory.exists()) return 0;
      var total = 0;
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          total++;
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes every cached lyric file and reports how many were removed.
  ///
  /// The list is per song and has no version marker, so a plugin that starts
  /// answering better — or a listener who imported the wrong `.lrc` — otherwise
  /// has no way to see the new reply. Unavailable storage is not an error: the
  /// caller only loses the count.
  Future<int> clear() async {
    var removed = 0;
    try {
      final directory = Directory(
        '${(await _support()).path}${Platform.pathSeparator}cached_lyrics',
      );
      if (!await directory.exists()) return 0;
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          await entity.delete();
          removed++;
        } catch (_) {
          // A file another process holds open is skipped, not retried.
        }
      }
    } catch (_) {
      return removed;
    }
    return removed;
  }
}
