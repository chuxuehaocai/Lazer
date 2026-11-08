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
          pureMusic: data['pureMusic'] == true,
        );
        if (payload.hasTimedLyric || payload.pureMusic) return payload;
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
      'lrc': payload.lrc,
      'yrc': payload.yrc,
      'tlyric': payload.tlyric,
      'ytlrc': payload.ytlrc,
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
}
