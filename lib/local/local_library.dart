import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/audio_quality.dart';
import '../data/models.dart';
import '../state/build_safe_notifier.dart';
import 'coalescing_writer.dart';

/// Where a file in the local library came from.
enum LocalTrackSource { download, scan }

/// Stable identifier for a file the service does not know about. Keeping local
/// ids away from numeric NetEase ids stops artwork and lyric lookups from
/// treating them as catalogue songs.
String localTrackIdForPath(String path) =>
    'local:${sha1.convert(utf8.encode(path))}';

/// One file in the local library: a download, an imported file or a scanned
/// file. [track.localPath] mirrors [path] so the player can skip the network.
class LocalTrack {
  LocalTrack({
    required this.track,
    required this.path,
    required this.source,
    required this.modifiedAt,
    required this.addedAt,
    this.quality,
    this.bytes,
    this.missing = false,
  });

  final Track track;

  /// Absolute path at runtime; the manifest stores container-independent
  /// paths for files under the app documents directory.
  final String path;
  final LocalTrackSource source;
  final AudioQuality? quality;
  final int? bytes;
  final DateTime modifiedAt;
  final DateTime addedAt;

  /// Set when the file disappeared since the last check.
  bool missing;

  bool get isDownload => source == LocalTrackSource.download;

  String get id => track.id;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'track': track.toJson(),
    'path': path,
    'source': source.name,
    'quality': quality?.name,
    'bytes': bytes,
    'modifiedAt': modifiedAt.millisecondsSinceEpoch,
    'addedAt': addedAt.millisecondsSinceEpoch,
  };

  factory LocalTrack.fromJson(Map<String, dynamic> json) => LocalTrack(
    track: Track.fromJson((json['track'] as Map<String, dynamic>?) ?? const {}),
    path: json['path'] as String? ?? '',
    source: json['source'] == 'download'
        ? LocalTrackSource.download
        : LocalTrackSource.scan,
    quality: json['quality'] == null
        ? null
        : AudioQualityInfo.parse(json['quality'] as String),
    bytes: (json['bytes'] as num?)?.toInt(),
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['modifiedAt'] as num?)?.toInt() ?? 0,
    ),
    addedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['addedAt'] as num?)?.toInt() ?? 0,
    ),
  );
}

class _ManifestData {
  const _ManifestData(this.tracks, this.scanRoots);
  final List<LocalTrack> tracks;
  final List<Object?> scanRoots;
}

class _ManifestWrite {
  const _ManifestWrite(this.tracks, this.scanRoots, this.documentsPath);
  final List<LocalTrack> tracks;
  final List<String> scanRoots;
  final String? documentsPath;
}

_ManifestData? _decodeManifest(String raw) {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return null;
  return _ManifestData(<LocalTrack>[
    for (final Object? value in decoded['tracks'] as List<Object?>? ?? const [])
      if (value is Map<String, dynamic>) LocalTrack.fromJson(value),
  ], decoded['scanRoots'] as List<Object?>? ?? const []);
}

/// Persistent index of local audio files.
///
/// The manifest lives in the application support directory. Downloads are
/// deleted with their file; scanned/imported files are only removed from the
/// index so the user's own copy is never touched by a library action.
class LocalLibrary extends ChangeNotifier with BuildSafeNotifier {
  LocalLibrary({
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? documentsDirectory,
    Future<bool> Function(String path)? fileExists,
  }) : _fileExists = fileExists ?? _defaultFileExists,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory;

  static const String _documentsPrefix = 'documents:';
  static const String _manifestName = 'local_library.json';

  static Future<bool> _defaultFileExists(String path) => File(path).exists();

  final Future<bool> Function(String path) _fileExists;
  final Future<Directory> Function() _supportDirectory;
  final Future<Directory> Function() _documentsDirectory;
  final List<LocalTrack> _tracks = <LocalTrack>[];
  Map<String, int>? _pathIndexes;
  final List<String> _scanRoots = <String>[];
  String? _documentsPath;
  Future<Directory?>? _supportFuture;
  int _tracksRevision = 0;
  bool _loaded = false;
  Future<void>? _loading;
  bool _verifying = false;
  bool _disposed = false;
  late final CoalescingWriter _writer = CoalescingWriter(() async {
    try {
      await _writeManifest();
    } catch (_) {
      // A failed manifest write must not interrupt playback or later updates.
    }
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  List<LocalTrack> get tracks => List<LocalTrack>.unmodifiable(_tracks);

  /// Changes whenever the track list or its missing-file status changes.
  int get tracksRevision => _tracksRevision;
  List<String> get scanRoots => List<String>.unmodifiable(_scanRoots);
  bool get loaded => _loaded;
  bool get verifying => _verifying;

  int get count => _tracks.length;
  int get availableCount =>
      _tracks.where((LocalTrack entry) => !entry.missing).length;
  int get totalBytes => _tracks.fold<int>(
    0,
    (int sum, LocalTrack entry) => sum + (entry.bytes ?? 0),
  );

  /// Restores the manifest. Missing files are checked in the background so a
  /// slow external drive cannot delay startup.
  Future<void> load() {
    final Future<void>? pending = _loading;
    if (pending != null) return pending;
    if (_loaded) return Future<void>.value();
    _loaded = true;
    final Future<void> loading = _loadManifest();
    _loading = loading;
    unawaited(
      loading.whenComplete(() {
        if (identical(_loading, loading)) _loading = null;
      }),
    );
    return loading;
  }

  Future<void> _loadManifest() async {
    try {
      final File? file = await _manifestFile();
      if (file == null || !await file.exists()) return;
      final String raw = await file.readAsString();
      final _ManifestData? decoded = raw.length < 65536
          ? _decodeManifest(raw)
          : await compute(_decodeManifest, raw, debugLabel: 'local-manifest');
      if (decoded == null || _disposed) return;
      await _resolveDocumentsPath();
      if (_disposed) return;
      for (final LocalTrack stored in decoded.tracks) {
        final LocalTrack entry = LocalTrack(
          track: stored.track,
          path: _decodePath(stored.path),
          source: stored.source,
          quality: stored.quality,
          bytes: stored.bytes,
          modifiedAt: stored.modifiedAt,
          addedAt: stored.addedAt,
        );
        if (entry.path.isEmpty) continue;
        _tracks.add(entry);
      }
      _pathIndexes = null;
      _tracksRevision++;
      for (final Object? value in decoded.scanRoots) {
        if (value is String &&
            value.isNotEmpty &&
            !_scanRoots.contains(value)) {
          _scanRoots.add(value);
        }
      }
      notifyListeners();
      unawaited(refreshMissing());
    } catch (_) {
      // A corrupt manifest must not block playback; downloads can be re-added.
    }
  }

  /// Re-checks every file and marks the records whose file disappeared.
  Future<void> refreshMissing() async {
    if (_verifying || _tracks.isEmpty) return;
    _verifying = true;
    // Opening the local music page starts this from `initState`, i.e. while the
    // framework is building. Reporting there marks every listener dirty in the
    // middle of that build, and a listener sitting in the subtree that is being
    // swapped out - the library card's `AnimatedBuilder` - is outside the build
    // scope, so Flutter throws "setState() or markNeedsBuild() called during
    // build". Hand the report to the next turn instead.
    await Future<void>.microtask(() {});
    if (_disposed) return;
    notifyListeners();
    bool changed = false;
    try {
      final List<LocalTrack> snapshot = List<LocalTrack>.of(_tracks);
      int indexedRevision = _tracksRevision;
      Set<LocalTrack>? live;
      bool isLive(LocalTrack entry) {
        if (indexedRevision != _tracksRevision) {
          live = Set<LocalTrack>.identity()..addAll(_tracks);
          indexedRevision = _tracksRevision;
        }
        return live?.contains(entry) ?? true;
      }

      for (final LocalTrack entry in snapshot) {
        if (_disposed) break;
        if (!isLive(entry)) continue;
        final bool exists = await _fileExists(entry.path);
        // A scan/import can replace this object while the filesystem request
        // is in flight. Never apply a stale result to a removed record.
        if (_disposed) break;
        if (!isLive(entry)) continue;
        if (entry.missing != !exists) {
          entry.missing = !exists;
          changed = true;
        }
      }
    } finally {
      _verifying = false;
      if (changed && !_disposed) {
        _tracksRevision++;
        notifyListeners();
      }
    }
  }

  /// Adds or refreshes entries. The same path is never indexed twice; a
  /// download record wins over a scanned record for the same file.
  Future<void> addTracks(Iterable<LocalTrack> entries) async {
    await load();
    await _resolveDocumentsPath();
    bool changed = false;
    final Map<String, int> indexes = _indexesByPath();
    for (final LocalTrack entry in entries) {
      if (entry.path.isEmpty) continue;
      final String path = _absolute(entry.path);
      final String key = _normalize(path);
      final int index = indexes[key] ?? -1;
      final LocalTrack normalized = LocalTrack(
        track: entry.track.copyWith(localPath: path),
        path: path,
        source: entry.source,
        quality: entry.quality,
        bytes: entry.bytes,
        modifiedAt: entry.modifiedAt,
        addedAt: entry.addedAt,
      );
      if (index < 0) {
        indexes[key] = _tracks.length;
        _tracks.add(normalized);
        changed = true;
        continue;
      }
      final LocalTrack existing = _tracks[index];
      final bool preferNew =
          normalized.source == LocalTrackSource.download ||
          existing.source != LocalTrackSource.download;
      final LocalTrack kept = preferNew ? normalized : existing;
      _tracks[index] = LocalTrack(
        track: kept.track,
        path: existing.path,
        source: kept.source,
        quality: normalized.quality ?? existing.quality,
        bytes: normalized.bytes ?? existing.bytes,
        modifiedAt: normalized.modifiedAt,
        addedAt: existing.addedAt,
      );
      changed = true;
    }
    if (!changed) return;
    _tracksRevision++;
    notifyListeners();
    await _persist();
  }

  /// The best existing local file for [track], preferring [quality] and then
  /// the highest tier. Filesystem checks are asynchronous so a slow drive
  /// cannot block the UI while a song or its lyrics are loading.
  Future<File?> localFileFor(Track track, {AudioQuality? quality}) async {
    final Future<void>? pending = _loading;
    if (pending != null) await pending;
    final String? localPath = track.localPath;
    final String? pathKey = localPath == null
        ? null
        : _normalize(_absolute(localPath));
    final List<LocalTrack> candidates = <LocalTrack>[
      for (final LocalTrack entry in _tracks)
        if (!entry.missing &&
            (entry.track.id == track.id ||
                pathKey != null && _normalize(entry.path) == pathKey))
          entry,
    ];
    int indexedRevision = _tracksRevision;
    Set<LocalTrack>? live;
    bool isLive(LocalTrack entry) {
      if (indexedRevision != _tracksRevision) {
        live = Set<LocalTrack>.identity()..addAll(_tracks);
        indexedRevision = _tracksRevision;
      }
      return live?.contains(entry) ?? true;
    }

    final List<LocalTrack> available = <LocalTrack>[];
    bool missingChanged = false;
    for (final LocalTrack entry in candidates) {
      if (_disposed) return null;
      if (!isLive(entry) || entry.missing) continue;
      final bool exists = await _fileExists(entry.path);
      if (_disposed) return null;
      if (!isLive(entry) || entry.missing) continue;
      if (exists) {
        available.add(entry);
      } else {
        entry.missing = true;
        missingChanged = true;
      }
    }
    if (missingChanged && !_disposed) {
      _tracksRevision++;
      notifyListeners();
    }
    LocalTrack? chosen;
    for (final LocalTrack entry in available) {
      if (!isLive(entry) || entry.missing) continue;
      if (chosen == null || _prefer(entry, chosen, quality)) chosen = entry;
    }
    return chosen == null ? null : File(chosen.path);
  }

  LocalTrack? entryForPath(String path) {
    final int? index = _indexesByPath()[_normalize(_absolute(path))];
    return index == null ? null : _tracks[index];
  }

  // Keep the first occurrence for old manifests containing duplicate paths.
  // Appends update this map; removals invalidate it because indexes shift.
  Map<String, int> _indexesByPath() => _pathIndexes ??= <String, int>{
    for (int i = _tracks.length - 1; i >= 0; i--)
      _normalize(_tracks[i].path): i,
  };

  /// Removes an entry. Downloaded files are deleted when [deleteFile] is true;
  /// scanned/imported files are never deleted by this API.
  Future<void> remove(LocalTrack entry, {bool deleteFile = false}) async {
    await load();
    final int? index = _indexesByPath()[_normalize(entry.path)];
    if (index == null) return;
    _tracks.removeAt(index);
    _pathIndexes = null;
    _tracksRevision++;
    if (deleteFile && entry.source == LocalTrackSource.download) {
      try {
        final File file = File(entry.path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    notifyListeners();
    await _persist();
  }

  /// Drops records whose file disappeared, without touching any file.
  Future<void> clearMissing() async {
    await load();
    final int before = _tracks.length;
    _tracks.removeWhere((LocalTrack entry) => entry.missing);
    if (_tracks.length == before) return;
    _pathIndexes = null;
    _tracksRevision++;
    notifyListeners();
    await _persist();
  }

  Future<void> addScanRoot(String path) async {
    await load();
    final String absolute = _absolute(path);
    if (_scanRoots.any((String root) => _samePath(root, absolute))) return;
    _scanRoots.add(absolute);
    notifyListeners();
    await _persist();
  }

  Future<void> removeScanRoot(String path) async {
    await load();
    final int before = _scanRoots.length;
    _scanRoots.removeWhere((String root) => _samePath(root, path));
    if (_scanRoots.length == before) return;
    notifyListeners();
    await _persist();
  }

  /// Removes every entry that came from a scan of [root] (or its children).
  Future<void> removeScannedUnder(String root) async {
    await load();
    final String normalizedRoot = _normalize(root);
    final String prefix = normalizedRoot.endsWith('/')
        ? normalizedRoot
        : '$normalizedRoot/';
    final int before = _tracks.length;
    _tracks.removeWhere((LocalTrack entry) {
      if (entry.source != LocalTrackSource.scan) return false;
      final String path = _normalize(entry.path);
      return path == normalizedRoot || path.startsWith(prefix);
    });
    if (_tracks.length == before) return;
    _pathIndexes = null;
    _tracksRevision++;
    notifyListeners();
    await _persist();
  }

  bool _prefer(LocalTrack a, LocalTrack b, AudioQuality? quality) {
    if (quality != null) {
      final bool aExact = a.quality == quality;
      final bool bExact = b.quality == quality;
      if (aExact != bExact) return aExact;
    }
    final int aRank = a.quality?.index ?? -1;
    final int bRank = b.quality?.index ?? -1;
    if (aRank != bRank) return aRank > bRank;
    return a.addedAt.isAfter(b.addedAt);
  }

  Future<File?> _manifestFile() async {
    try {
      _supportFuture ??= _supportDirectory();
      final Directory? directory = await _supportFuture;
      if (directory == null) return null;
      await directory.create(recursive: true);
      return File('${directory.path}${Platform.pathSeparator}$_manifestName');
    } catch (_) {
      return null;
    }
  }

  Future<void> _resolveDocumentsPath() async {
    if (_documentsPath != null) return;
    try {
      _documentsPath = _absolute((await _documentsDirectory()).path);
    } catch (_) {
      _documentsPath = null;
    }
  }

  Future<void> _persist() => _writer.request();

  Future<void> _writeManifest() async {
    final File? file = await _manifestFile();
    if (file == null) return;
    await _resolveDocumentsPath();
    final snapshot = _ManifestWrite(
      List<LocalTrack>.of(_tracks),
      List<String>.of(_scanRoots),
      _documentsPath,
    );
    final String json = snapshot.tracks.length < 128
        ? _encodeManifest(snapshot)
        : await compute(
            _encodeManifest,
            snapshot,
            debugLabel: 'local-manifest-write',
          );
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(json, flush: true);
    await temporary.rename(file.path);
  }

  static String _encodeManifest(_ManifestWrite snapshot) =>
      jsonEncode(<String, dynamic>{
        'version': 1,
        'tracks': <Map<String, dynamic>>[
          for (final LocalTrack entry in snapshot.tracks)
            <String, dynamic>{
              ...entry.toJson(),
              'path': _encodePath(entry.path, snapshot.documentsPath),
            },
        ],
        'scanRoots': snapshot.scanRoots,
      });

  static String _encodePath(String path, String? documents) {
    if (documents == null) return path;
    final String? relative = _relativeWithin(documents, path);
    if (relative == null || relative.isEmpty) return path;
    return '$_documentsPrefix$relative';
  }

  String _decodePath(String stored) {
    if (!stored.startsWith(_documentsPrefix)) return stored;
    final String? documents = _documentsPath;
    if (documents == null) return stored;
    final String relative = stored.substring(_documentsPrefix.length);
    return '$documents${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}';
  }

  String _absolute(String path) {
    try {
      String absolute = File(path).absolute.path;
      if (Platform.isWindows) absolute = absolute.replaceAll('/', '\\');
      return absolute;
    } catch (_) {
      return path;
    }
  }

  bool _samePath(String a, String b) {
    final String left = _normalize(a);
    final String right = _normalize(b);
    return left == right;
  }

  static String _normalize(String path) {
    String value = path.replaceAll('\\', '/');
    while (value.endsWith('/') && value.length > 1) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  static String? _relativeWithin(String root, String path) {
    final String normalizedRoot = _normalize(root);
    final String normalizedPath = _normalize(path);
    if (normalizedPath == normalizedRoot) return '';
    final String prefix = normalizedRoot.endsWith('/')
        ? normalizedRoot
        : '$normalizedRoot/';
    if (!normalizedPath.startsWith(prefix)) return null;
    return path
        .substring(root.length)
        .replaceFirst(RegExp(r'^[\\/]'), '')
        .replaceAll('\\', '/');
  }
}
