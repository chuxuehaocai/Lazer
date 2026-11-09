// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/audio_quality.dart';
import '../data/models.dart';
import '../state/build_safe_notifier.dart';

/// Where a file in the local library came from.
enum LocalTrackSource { download, scan, cache }

String localTrackIdForPath(String path) =>
    'local:${sha1.convert(utf8.encode(path))}';

/// One file in the local library: a download, an imported file or a scanned
/// file.
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
  final String path;
  final LocalTrackSource source;
  final AudioQuality? quality;
  final int? bytes;
  final DateTime modifiedAt;
  final DateTime addedAt;
  bool missing;

  bool get isDownload => source == LocalTrackSource.download;
  bool get isCache => source == LocalTrackSource.cache;
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
    track: Track.fromJson(
      (json['track'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
    ),
    path: json['path'] as String? ?? '',
    source: switch (json['source']) {
      'download' => LocalTrackSource.download,
      'cache' => LocalTrackSource.cache,
      _ => LocalTrackSource.scan,
    },
    quality: AudioQuality.values
        .where((value) => value.name == json['quality'])
        .firstOrNull,
    bytes: (json['bytes'] as num?)?.toInt(),
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['modifiedAt'] as num?)?.toInt() ?? 0,
    ),
    addedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['addedAt'] as num?)?.toInt() ?? 0,
    ),
  );
}

/// Imported audio bytes, kept in the browser's IndexedDB. A track's `path` is
/// its store key, and playback resolves it to an object URL.
class LocalBlobStore {
  LocalBlobStore._();
  static final LocalBlobStore instance = LocalBlobStore._();

  final Map<String, Uint8List> _memory = <String, Uint8List>{};
  final Map<String, String> _urls = <String, String>{};
  Object? _db;

  Future<dynamic> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final factory = html.window.indexedDB;
    if (factory == null) throw StateError('浏览器不能保存本地音乐');
    final db = await factory.open(
      'lazer.local',
      version: 1,
      onUpgradeNeeded: (event) {
        final created = (event.target as dynamic).result;
        final names = created.objectStoreNames as List?;
        if (names == null || !names.contains('tracks')) {
          created.createObjectStore('tracks', keyPath: 'id');
        }
      },
    );
    return _db = db;
  }

  Future<void> put(String id, Uint8List bytes) async {
    _memory[id] = bytes;
    try {
      final db = await _open();
      await db
          .transaction('tracks', 'readwrite')
          .objectStore('tracks')
          .put(<String, Object?>{'id': id, 'bytes': bytes});
    } catch (_) {
      // Private mode can refuse IndexedDB; the session keeps the bytes.
    }
  }

  Future<Uint8List?> _bytes(String id) async {
    final cached = _memory[id];
    if (cached != null) return cached;
    try {
      final db = await _open();
      final request = db
          .transaction('tracks', 'readonly')
          .objectStore('tracks')
          .getObject(id);
      await request.onSuccess.first;
      final row = request.result;
      if (row is Map) {
        final bytes = row['bytes'];
        if (bytes is Uint8List) return _memory[id] = bytes;
        if (bytes is ByteBuffer) {
          return _memory[id] = Uint8List.view(bytes);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String?> url(String id) async {
    final cached = _urls[id];
    if (cached != null) return cached;
    final bytes = await _bytes(id);
    if (bytes == null) return null;
    return _urls[id] = html.Url.createObjectUrl(html.Blob(<Object>[bytes]));
  }

  Future<void> remove(String id) async {
    _memory.remove(id);
    final url = _urls.remove(id);
    if (url != null) html.Url.revokeObjectUrl(url);
    try {
      final db = await _open();
      await db
          .transaction('tracks', 'readwrite')
          .objectStore('tracks')
          .delete(id);
    } catch (_) {}
  }

  Future<void> clear() async {
    for (final url in _urls.values) {
      html.Url.revokeObjectUrl(url);
    }
    _urls.clear();
    _memory.clear();
    try {
      final db = await _open();
      await db.transaction('tracks', 'readwrite').objectStore('tracks').clear();
    } catch (_) {}
  }
}

/// Browser library: imported files live in [LocalBlobStore], metadata in
/// memory for the session.
class LocalLibrary extends ChangeNotifier with BuildSafeNotifier {
  LocalLibrary({
    Object? fileExists,
    Object? supportDirectory,
    Object? documentsDirectory,
  });

  final List<LocalTrack> _tracks = <LocalTrack>[];
  int _tracksRevision = 0;
  bool _loaded = false;

  List<LocalTrack> get tracks => List<LocalTrack>.unmodifiable(_tracks);
  List<Track> get playableTracks => <Track>[
    for (final entry in _tracks)
      if (!entry.missing) entry.track,
  ];
  int get tracksRevision => _tracksRevision;
  List<String> get scanRoots => const <String>[];
  bool get loaded => _loaded;
  bool get verifying => false;
  int get count => _tracks.length;
  int get availableCount =>
      _tracks.where((entry) => !entry.missing).length;
  int get totalBytes =>
      _tracks.fold<int>(0, (sum, entry) => sum + (entry.bytes ?? 0));

  Future<void> load() async {
    _loaded = true;
  }

  Future<void> refreshMissing() async {}

  Future<void> addTracks(Iterable<LocalTrack> entries) async {
    for (final entry in entries) {
      final index = _tracks.indexWhere((value) => value.id == entry.id);
      if (index >= 0) {
        _tracks[index] = entry;
      } else {
        _tracks.add(entry);
      }
    }
    _tracksRevision++;
    _loaded = true;
    notifyListeners();
  }

  Future<String?> playbackUrl(Track track, {AudioQuality? quality}) async {
    final entry = _tracks
        .where((value) => value.id == track.id || value.path == track.localPath)
        .firstOrNull;
    if (entry == null) return null;
    return LocalBlobStore.instance.url(entry.path);
  }

  Future<File?> localFileFor(Track track, {AudioQuality? quality}) async => null;
  LocalTrack? entryForPath(String path) => _tracks
      .where((value) => value.path == path)
      .firstOrNull;
  Future<void> remove(LocalTrack entry, {bool deleteFile = false}) async {
    _tracks.remove(entry);
    _tracksRevision++;
    await LocalBlobStore.instance.remove(entry.path);
    notifyListeners();
  }

  Future<void> clearMissing() async {
    _tracks.removeWhere((entry) => entry.missing);
    _tracksRevision++;
    notifyListeners();
  }

  Future<void> addScanRoot(String path) async {}
  Future<void> removeScanRoot(String path) async {}
  Future<void> removeScannedUnder(String root) async {}
}
