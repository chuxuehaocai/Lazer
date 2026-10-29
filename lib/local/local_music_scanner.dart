// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models.dart';
import 'local_audio_probe.dart';
import 'local_library.dart';

class LocalScanResult {
  const LocalScanResult({
    required this.tracks,
    this.skipped = 0,
    this.canceled = false,
  });

  final List<LocalTrack> tracks;

  /// Files under the root that are not audio or could not be read.
  final int skipped;
  final bool canceled;
}

/// Walks music folders and builds [LocalTrack] entries.
///
/// Files whose size and modification time are unchanged reuse the previous
/// metadata, so rescanning a large library only probes new or edited files.
class LocalMusicScanner {
  LocalMusicScanner({LocalAudioProbe? probe})
    : probe = probe ?? const LocalAudioProbe();

  final LocalAudioProbe probe;

  static const Set<String> extensions = <String>{
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'wav',
    'mp4',
  };

  static const int _maxDepth = 8;
  static const int _maxFiles = 5000;

  /// Root the platform suggests for "scan my music".
  Future<Directory?> defaultRoot() async {
    try {
      if (Platform.isWindows) {
        final String? home = Platform.environment['USERPROFILE'];
        if (home != null && home.isNotEmpty) return Directory('$home\\Music');
      } else if (Platform.isMacOS) {
        final String? home = Platform.environment['HOME'];
        if (home != null && home.isNotEmpty) return Directory('$home/Music');
      } else if (Platform.isLinux) {
        final String? music =
            Platform.environment['XDG_MUSIC_DIR'] ??
            (Platform.environment['HOME'] == null
                ? null
                : '${Platform.environment['HOME']}/Music');
        if (music != null) return Directory(music);
      } else if (Platform.isAndroid) {
        return Directory('/storage/emulated/0/Music');
      } else if (Platform.isIOS) {
        return await getApplicationDocumentsDirectory();
      }
    } catch (_) {}
    return null;
  }

  /// Scans [root] recursively. [onProgress] receives the number of audio files
  /// found so far and the file currently being probed.
  Future<LocalScanResult> scan(
    Directory root, {
    Iterable<LocalTrack> existing = const <LocalTrack>[],
    bool Function()? isCanceled,
    void Function(int found, String current)? onProgress,
  }) async {
    final Map<String, LocalTrack> known = <String, LocalTrack>{
      for (final LocalTrack entry in existing) _normalize(entry.path): entry,
    };
    final List<LocalTrack> found = <LocalTrack>[];
    final List<Directory> pending = <Directory>[root];
    int visited = 0;
    int skipped = 0;
    bool canceled = false;
    final DateTime now = DateTime.now();
    while (pending.isNotEmpty) {
      if (isCanceled?.call() ?? false) {
        canceled = true;
        break;
      }
      final Directory directory = pending.removeLast();
      try {
        await for (final FileSystemEntity entity in directory.list(
          followLinks: false,
        )) {
          if (isCanceled?.call() ?? false) {
            canceled = true;
            break;
          }
          final String name = _baseName(entity.path);
          if (name.startsWith('.') || _ignoredDirectories.contains(name)) {
            continue;
          }
          if (entity is Directory) {
            if (_depthOf(entity.path, root.path) < _maxDepth) {
              pending.add(entity);
            }
            continue;
          }
          if (entity is! File) continue;
          if (!extensions.contains(_extension(entity.path))) continue;
          visited++;
          if (found.length >= _maxFiles) break;
          try {
            final FileStat stat = await entity.stat();
            final String path = _absolute(entity.path);
            final LocalTrack? previous = known[_normalize(path)];
            LocalTrack entry;
            if (previous != null &&
                previous.bytes == stat.size &&
                previous.modifiedAt.millisecondsSinceEpoch ==
                    stat.modified.millisecondsSinceEpoch) {
              entry = previous;
            } else {
              final LocalAudioMetadata metadata = await probe.probe(entity);
              final String title = metadata.title.trim().isEmpty
                  ? LocalAudioProbe.fromFileName(path).title
                  : metadata.title.trim();
              final String artist = metadata.artist.trim();
              final String album = metadata.album.trim();
              entry = LocalTrack(
                track: Track(
                  id: localTrackIdForPath(path),
                  title: title,
                  artist: artist.isEmpty ? '未知歌手' : artist,
                  album: album.isEmpty ? '未知专辑' : album,
                  duration: metadata.duration,
                  coverSeed: _seedFor(path),
                  localPath: path,
                ),
                path: path,
                source: LocalTrackSource.scan,
                bytes: stat.size,
                modifiedAt: stat.modified,
                addedAt: previous?.addedAt ?? now,
              );
            }
            found.add(entry);
            onProgress?.call(found.length, path);
          } catch (_) {
            skipped++;
          }
          if (visited % 20 == 0) {
            // Yield so the scan never blocks a frame for long.
            await Future<void>.delayed(Duration.zero);
          }
        }
      } catch (_) {
        // A directory can become inaccessible while it is being enumerated;
        // keep entries already read and continue with the remaining folders.
        skipped++;
      }
      if (canceled || found.length >= _maxFiles) break;
    }
    return LocalScanResult(tracks: found, skipped: skipped, canceled: canceled);
  }

  static const Set<String> _ignoredDirectories = <String>{
    r'$RECYCLE.BIN',
    'System Volume Information',
    '@eaDir',
    'node_modules',
  };

  static String _extension(String path) {
    final String name = _baseName(path);
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String _baseName(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final List<String> parts = normalized.split('/');
    return parts.isEmpty ? '' : parts.last;
  }

  static int _depthOf(String path, String root) =>
      _normalize(path).split('/').length - _normalize(root).split('/').length;

  static String _normalize(String path) {
    String value = path.replaceAll('\\', '/');
    while (value.endsWith('/') && value.length > 1) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  static String _absolute(String path) {
    try {
      String absolute = File(path).absolute.path;
      if (Platform.isWindows) absolute = absolute.replaceAll('/', '\\');
      return absolute;
    } catch (_) {
      return path;
    }
  }

  static int _seedFor(String path) {
    final List<int> digest = sha1.convert(utf8.encode(path)).bytes;
    return (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
  }
}
