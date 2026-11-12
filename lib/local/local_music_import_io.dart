// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';

import '../data/models.dart';
import 'local_audio_probe.dart';
import 'local_library.dart';

/// Extensions the local library accepts. The probe reads the full tag set for
/// MP3, FLAC, M4A and WAV; anything else still imports with its file name as
/// the title, which is how Ogg and AAC files end up readable too.
const List<String> localAudioExtensions = <String>[
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'oga',
  'opus',
  'wav',
  'wave',
  'mp4',
];

/// Filter offered to the platform file chooser.
const XTypeGroup localAudioTypeGroup = XTypeGroup(
  label: '本地音乐',
  extensions: localAudioExtensions,
  mimeTypes: <String>['audio/*'],
  uniformTypeIdentifiers: <String>['public.audio'],
);

/// Opens the system file chooser. Returns the chosen paths; an empty list means
/// the chooser was dismissed.
typedef LocalAudioFilePicker = Future<List<String>> Function();

/// The production picker. It is a top-level function so [LocalMusicImporter]
/// can use it as a const default and tests can swap in their own.
Future<List<String>> openLocalAudioPicker() async {
  final List<XFile> files = await openFiles(
    acceptedTypeGroups: const <XTypeGroup>[localAudioTypeGroup],
  );
  return <String>[for (final XFile file in files) file.path];
}

/// What one import pass did. [skipped] counts files already in the library (or
/// picked twice), [failed] counts paths that could not be read.
class LocalImportResult {
  const LocalImportResult({this.added = 0, this.skipped = 0, this.failed = 0});

  static const LocalImportResult empty = LocalImportResult();

  final int added;
  final int skipped;
  final int failed;

  int get total => added + skipped + failed;
  bool get isEmpty => total == 0;
}

/// Raised when the platform chooser itself is unavailable, so the UI can say
/// something useful instead of blaming the files.
class LocalImportException implements Exception {
  const LocalImportException(this.message);

  final String message;

  @override
  String toString() => 'LocalImportException: $message';
}

/// Imports audio files the service knows nothing about into [LocalLibrary].
///
/// The interface normally calls [importInto]; tests and any future drag-and-drop
/// surface can call [addPaths] with files they already have. Imported files are
/// recorded as [LocalTrackSource.scan], so removing them from the library never
/// touches the listener's own copy.
class LocalMusicImporter {
  const LocalMusicImporter({
    this.probe = const LocalAudioProbe(),
    this.picker = openLocalAudioPicker,
  });

  final LocalAudioProbe probe;
  final LocalAudioFilePicker picker;

  /// Asks the listener for files and records them.
  Future<LocalImportResult> importInto(LocalLibrary library) async {
    final List<String> paths;
    try {
      paths = await picker();
    } catch (_) {
      throw const LocalImportException('无法打开文件选择器，请检查系统权限后重试。');
    }
    if (paths.isEmpty) return LocalImportResult.empty;
    return addPaths(library, paths);
  }

  /// Reads [paths] and adds them. Files already indexed are refreshed instead
  /// of duplicated, so importing the same folder twice is harmless.
  Future<LocalImportResult> addPaths(
    LocalLibrary library,
    Iterable<String> paths,
  ) async {
    await library.load();
    int added = 0;
    int skipped = 0;
    int failed = 0;
    final Set<String> seen = <String>{};
    final List<LocalTrack> entries = <LocalTrack>[];
    for (final String raw in paths) {
      final String path = raw.trim();
      if (path.isEmpty) {
        failed++;
        continue;
      }
      if (!seen.add(_pathKey(path))) {
        skipped++;
        continue;
      }
      final LocalTrack? entry = await _entryFor(path);
      if (entry == null) {
        failed++;
        continue;
      }
      if (library.entryForPath(entry.path) != null) {
        skipped++;
      } else {
        added++;
      }
      entries.add(entry);
    }
    if (entries.isNotEmpty) await library.addTracks(entries);
    return LocalImportResult(added: added, skipped: skipped, failed: failed);
  }

  Future<LocalTrack?> _entryFor(String path) async {
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      final String absolute = file.absolute.path;
      final FileStat stat = await file.stat();
      final LocalAudioMetadata metadata = await probe.probe(file);
      final String title = metadata.title.trim().isEmpty
          ? LocalAudioProbe.fromFileName(absolute).title
          : metadata.title.trim();
      final String artist = metadata.artist.trim();
      final String album = metadata.album.trim();
      final String? artwork = await LocalAudioProbe.artworkUriFor(absolute);
      return LocalTrack(
        track: Track(
          id: localTrackIdForPath(absolute),
          title: title,
          artist: artist.isEmpty ? Track.unknownArtist : artist,
          album: album.isEmpty ? Track.unknownAlbum : album,
          duration: metadata.duration,
          coverSeed: _coverSeed(absolute),
          coverUrl: artwork,
          localPath: absolute,
        ),
        path: absolute,
        source: LocalTrackSource.scan,
        bytes: stat.size,
        modifiedAt: stat.modified,
        addedAt: DateTime.now(),
      );
    } catch (_) {
      // A locked, truncated or permission-denied file is reported as failed
      // and the rest of the selection still imports.
      return null;
    }
  }

  /// Same file on Windows regardless of separators or letter case.
  String _pathKey(String path) {
    final String normalized = File(path).absolute.path.replaceAll('\\', '/');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  /// Deterministic seed for the generative cover, so a file keeps the same
  /// artwork across launches and re-imports.
  int _coverSeed(String path) {
    final Digest digest = sha1.convert(utf8.encode(_pathKey(path)));
    return (digest.bytes[0] << 16) | (digest.bytes[1] << 8) | digest.bytes[2];
  }
}
