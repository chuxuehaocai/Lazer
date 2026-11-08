import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../storage/app_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/audio_quality.dart';
import '../data/models.dart';
import '../local/coalescing_writer.dart';
import '../local/local_library.dart';
import '../state/build_safe_notifier.dart';
import 'media_cache.dart';

enum PlaybackCacheMode { recent, intelligent }

class _ListeningHistory {
  _ListeningHistory(this.track, this.plays, {int? lastPlayed})
    : lastPlayed = lastPlayed ?? (plays.isEmpty ? 0 : plays.last);

  Track track;
  final List<int> plays;
  int lastPlayed;
}

/// Keeps complete playback downloads in the local library. Explicit downloads
/// and imported files are never counted toward, or removed by, this policy.
class PlaybackCacheController extends ChangeNotifier with BuildSafeNotifier {
  PlaybackCacheController({
    required this.audioCache,
    required this.library,
    Future<Directory> Function()? supportDirectory,
    DateTime Function()? now,
  }) : _supportDirectory = supportDirectory ?? appSupportDirectory,
       _now = now ?? DateTime.now {
    _observedLibraryRevision = library.tracksRevision;
    library.addListener(_libraryChanged);
  }

  static const String modeKey = 'lazer_playback_cache_mode';
  static const String limitKey = 'lazer_playback_cache_limit';
  static const int defaultMaximumTracks = 50;
  static const Duration historyWindow = Duration(days: 30);

  final AudioCache audioCache;
  final LocalLibrary library;
  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _now;
  final Map<String, _ListeningHistory> _history = <String, _ListeningHistory>{};
  final Map<String, String> _pendingDeletes = <String, String>{};
  final Map<String, File> _retainedFiles = <String, File>{};
  Future<void>? _loading;
  Future<void> _operations = Future<void>.value();
  File? _manifest;
  bool _disposed = false;
  int _generation = 0;
  int _observedLibraryRevision = -1;
  String? _currentTrackId;
  PlaybackCacheMode _mode = PlaybackCacheMode.recent;
  int _maximumTracks = defaultMaximumTracks;

  PlaybackCacheMode get mode => _mode;
  int get maximumTracks => _maximumTracks;
  int get cachedCount => library.tracks.where((entry) => entry.isCache).length;

  late final CoalescingWriter _writer = CoalescingWriter(_saveHistory);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _mode = prefs.getString(modeKey) == PlaybackCacheMode.intelligent.name
          ? PlaybackCacheMode.intelligent
          : PlaybackCacheMode.recent;
      _maximumTracks = (prefs.getInt(limitKey) ?? defaultMaximumTracks).clamp(
        1,
        500,
      );
      final Directory support = await _supportDirectory();
      await support.create(recursive: true);
      _manifest = File(
        '${support.path}${Platform.pathSeparator}playback_cache.json',
      );
      if (await _manifest!.exists()) {
        final Object? decoded = jsonDecode(await _manifest!.readAsString());
        if (decoded is Map<String, dynamic>) {
          for (final Object? value
              in decoded['pendingDeletes'] as List? ?? const []) {
            if (value is Map<String, dynamic> &&
                value['path'] is String &&
                value['id'] is String) {
              _pendingDeletes[value['path'] as String] = value['id'] as String;
            }
          }
          for (final Object? value in decoded['history'] as List? ?? const []) {
            if (value is! Map<String, dynamic>) continue;
            try {
              final Track track = Track.fromJson(
                value['track'] as Map<String, dynamic>,
              );
              final List<int> plays = <int>[
                for (final Object? time in value['plays'] as List? ?? const [])
                  if (time is num) time.toInt(),
              ]..sort();
              _history[track.id] = _ListeningHistory(
                track,
                plays,
                lastPlayed: (value['lastPlayed'] as num?)?.toInt(),
              );
            } catch (_) {
              // One outdated entry must not discard the rest of the history.
            }
          }
        }
      }
    } catch (_) {
      // Playback also works when preferences or app storage are unavailable.
    }
    await library.load();
    if (_disposed) return;
    _libraryChanged(force: true);
    await _flushPendingDeletes();
    _trimHistory();
    await _enforceLimit();
    if (!_disposed) notifyListeners();
  }

  Future<void> setMode(PlaybackCacheMode value) async {
    await load();
    if (_disposed || value == _mode) return;
    _mode = value;
    notifyListeners();
    await _serialize(_enforceLimit);
    await (await SharedPreferences.getInstance()).setString(
      modeKey,
      value.name,
    );
  }

  Future<void> setMaximumTracks(int value) async {
    await load();
    final int next = value.clamp(1, 500);
    if (_disposed || next == _maximumTracks) return;
    _maximumTracks = next;
    notifyListeners();
    await _serialize(_enforceLimit);
    await (await SharedPreferences.getInstance()).setInt(limitKey, next);
  }

  /// Called only once playback has opened the source, including gapless
  /// hand-offs. Waiting for the existing download never delays the player.
  Future<void> recordPlayed(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async {
    await load();
    if (_disposed) return;
    final bool changedTrack = _currentTrackId != track.id;
    _currentTrackId = track.id;
    // Opening an imported song also releases the previous service decoder.
    // In particular, a Windows file deferred by clear() can now be removed.
    await _serialize(_flushPendingDeletes);
    if (!track.isServiceTrack) {
      await _writer.request();
      return;
    }
    final int generation = _generation;
    final int time = _now().millisecondsSinceEpoch;
    final _ListeningHistory history = _history.putIfAbsent(
      track.id,
      () => _ListeningHistory(track, <int>[]),
    );
    history.track = track;
    // Reopening the same source for a quality change is still one listen.
    if (changedTrack ||
        history.plays.isEmpty ||
        time - history.lastPlayed >=
            const Duration(seconds: 30).inMilliseconds) {
      history.plays.add(time);
    }
    history.lastPlayed = time;
    _trimHistory();
    await _writer.request();
    final cached = await audioCache.completedFor(track.id, preferred: quality);
    if (_disposed || generation != _generation || cached == null) return;
    audioCache.disk.retainFile(cached.file);
    try {
      await _serialize(() async {
        if (generation != _generation || !await cached.file.exists()) return;
        final List<LocalTrack> old = library.tracks
            .where((entry) => entry.isCache && entry.track.id == track.id)
            .toList();
        for (final LocalTrack entry in old) {
          if (File(entry.path).uri.normalizePath() ==
              cached.file.uri.normalizePath()) {
            continue;
          }
          // Only remove the old rendition. Removing all qualities here would
          // delete the completed file that is about to replace it as well.
          await _removeCached(entry, allRenditions: false);
        }
        _pendingDeletes.removeWhere(
          (path, _) =>
              File(path).uri.normalizePath() == cached.file.uri.normalizePath(),
        );
        final FileStat stat = await cached.file.stat();
        await library.addTracks(<LocalTrack>[
          LocalTrack(
            track: history.track,
            path: cached.file.path,
            source: LocalTrackSource.cache,
            quality: cached.quality,
            bytes: stat.size,
            modifiedAt: stat.modified,
            addedAt: _now(),
          ),
        ]);
        await _enforceLimit();
        await _writer.request();
        if (!_disposed) notifyListeners();
      });
    } finally {
      if (!_retainedFiles.values.any(
        (file) => file.uri.normalizePath() == cached.file.uri.normalizePath(),
      )) {
        audioCache.disk.releaseFile(cached.file);
      }
    }
  }

  Future<void> clear() async {
    await load();
    _generation++;
    await _serialize(() async {
      for (final LocalTrack entry in library.tracks.where(
        (entry) => entry.isCache,
      )) {
        await _removeCached(entry);
      }
      await _writer.request();
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _enforceLimit() async {
    _trimHistory();
    final List<LocalTrack> cached = library.tracks
        .where((entry) => entry.isCache)
        .toList();
    cached.sort((a, b) {
      final _ListeningHistory? aHistory = _history[a.track.id];
      final _ListeningHistory? bHistory = _history[b.track.id];
      if (_mode == PlaybackCacheMode.intelligent) {
        final int frequency = (bHistory?.plays.length ?? 0).compareTo(
          aHistory?.plays.length ?? 0,
        );
        if (frequency != 0) return frequency;
      }
      return (bHistory?.lastPlayed ?? b.addedAt.millisecondsSinceEpoch)
          .compareTo(aHistory?.lastPlayed ?? a.addedAt.millisecondsSinceEpoch);
    });
    while (cached.length > _maximumTracks) {
      // Intelligent mode may reject the currently playing, less frequent
      // song. Its file stays retained until the decoder switches sources.
      final LocalTrack victim = cached.removeLast();
      await _removeCached(victim);
    }
    await _writer.request();
  }

  void _libraryChanged({bool force = false}) {
    if (_disposed) return;
    final revision = library.tracksRevision;
    if (!force && revision == _observedLibraryRevision) return;
    _observedLibraryRevision = revision;
    final Map<String, File> current = <String, File>{
      for (final LocalTrack entry in library.tracks)
        if (entry.isCache) entry.path: File(entry.path),
      for (final String path in _pendingDeletes.keys) path: File(path),
    };
    for (final MapEntry<String, File> entry in _retainedFiles.entries) {
      if (!current.containsKey(entry.key)) {
        audioCache.disk.releaseFile(entry.value);
      }
    }
    for (final File file in current.values) {
      audioCache.disk.retainFile(file);
    }
    _retainedFiles
      ..clear()
      ..addAll(current);
  }

  Future<void> _removeCached(
    LocalTrack entry, {
    bool allRenditions = true,
  }) async {
    final File file = File(entry.path);
    _pendingDeletes[entry.path] = entry.track.id;
    _libraryChanged(force: true);
    await library.remove(entry);
    if (allRenditions) {
      await audioCache.removeTrack(entry.track.id, exceptFile: file);
    }
    // Do not unlink an open decoder file. Remove its library row immediately,
    // then delete the file after switching tracks or reopening the app.
    await _flushPendingDeletes();
  }

  Future<void> _flushPendingDeletes() async {
    for (final MapEntry<String, String> entry
        in _pendingDeletes.entries.toList()) {
      if (entry.value == _currentTrackId) continue;
      try {
        final File file = File(entry.key);
        if (await file.exists()) await file.delete();
        _pendingDeletes.remove(entry.key);
      } catch (_) {
        // A decoder may still be releasing the previous source.
      }
    }
    _libraryChanged(force: true);
  }

  void _trimHistory() {
    final int cutoff = _now().subtract(historyWindow).millisecondsSinceEpoch;
    for (final _ListeningHistory history in _history.values) {
      history.plays.removeWhere((time) => time < cutoff);
    }
    final List<String> ordered = _history.keys.toList()
      ..sort(
        (a, b) => _history[b]!.lastPlayed.compareTo(_history[a]!.lastPlayed),
      );
    for (final String id in ordered.skip(1000)) {
      _history.remove(id);
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final Future<void> next = _operations.then((_) async {
      if (!_disposed) await operation();
    });
    // Storage failures must not poison later updates or playback.
    _operations = next.catchError((Object _) {});
    return _operations;
  }

  Future<void> _saveHistory() async {
    final File? manifest = _manifest;
    if (manifest == null || _disposed) return;
    try {
      final String json = jsonEncode(<String, Object>{
        'version': 1,
        'pendingDeletes': <Map<String, String>>[
          for (final MapEntry<String, String> entry in _pendingDeletes.entries)
            <String, String>{'path': entry.key, 'id': entry.value},
        ],
        'history': <Map<String, Object>>[
          for (final _ListeningHistory history in _history.values)
            <String, Object>{
              'track': history.track.toJson(),
              'plays': history.plays,
              'lastPlayed': history.lastPlayed,
            },
        ],
      });
      final File temporary = File('${manifest.path}.tmp');
      await temporary.writeAsString(json, flush: true);
      await temporary.rename(manifest.path);
    } catch (_) {}
  }

  /// Writes play counts, recency and the pending-delete queue now.
  ///
  /// The periodic save is a coalesced write; a process that goes away between
  /// two writes loses the last window of history, which is also the input of
  /// the eviction policy. The lifecycle hooks await this.
  Future<void> flushHistory() async {
    if (_disposed) return;
    await _serialize(_saveHistory);
  }

  @override
  void dispose() {
    _disposed = true;
    library.removeListener(_libraryChanged);
    for (final File file in _retainedFiles.values) {
      audioCache.disk.releaseFile(file);
    }
    _retainedFiles.clear();
    super.dispose();
  }
}
