// Growing-file cache for network sources.
//
// The engine cannot open an HTTP URL itself (its C ABI takes a path or a byte
// reader), so streaming works the way the master branch does it: download into a
// cache file while the engine reads it through the bridge's blocking reader. The
// file is the buffer — a read for a byte range that has not landed yet waits for
// the download instead of failing, which is also what makes seek-before-downloaded
// behave like a slow file rather than a short one.
//
// The download is the only source of bytes: nothing here fetches a range on
// demand, so what the player may seek to is decided by how much of the track has
// landed. The entry publishes that size as soon as the response announces it,
// because a demuxer can only turn a seek's timestamp into a byte offset with it.
//
// Only the file and the download live here; the reader lifecycle belongs to
// `NativeStreamReader` and the transport to `NativeAudioEngine`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'audio_stream_entry.dart';
import '../../utils/system_http.dart';

export 'audio_stream_entry.dart';

/// Supplies the cache directory.
///
/// Injected rather than looked up so this file has no Flutter dependency: the
/// download/resume logic is exercised by plain-Dart checks (`tool/`), which the
/// app-side factory (`engine_factory.dart`) cannot be.
typedef CacheDirectoryProvider = Future<Directory> Function();

/// How long the response headers may take before the download is abandoned.
///
/// The client's connect timeout only covers the connection itself: a server that
/// accepts the TCP connection and then never answers used to park the download
/// forever, and a download that is merely *slow* still reports `failure == null`,
/// which is the one state the engine's stall recovery cannot get out of.
const Duration _responseHeaderTimeout = Duration(seconds: 20);

/// Owns the cache directory and the entries that are in use.
class AudioStreamCache {
  /// The directory provider is positional so it can be an initializing formal
  /// (`this._directory`); a named parameter cannot carry a private name.
  AudioStreamCache(
    this._directory, {
    HttpClient? client,
    this.maximumEntries = 8,
    this.responseHeaderTimeout = _responseHeaderTimeout,
  }) : assert(maximumEntries > 0),
       _client =
           client ??
           // Keep-alive client with a bounded connect timeout; `close()` forces
           // it shut. Injectable so a check can drive it.
           (HttpClient()
             ..connectionTimeout = const Duration(seconds: 15)
             ..findProxy = SystemHttpProxy.currentFindProxyRule);

  final CacheDirectoryProvider _directory;
  final HttpClient _client;

  /// How many files are kept on disk; the least recently opened entry is evicted.
  final int maximumEntries;

  /// How long a download may wait for response headers before failing.
  final Duration responseHeaderTimeout;

  final Map<int, AudioStreamEntry> _entries = <int, AudioStreamEntry>{};
  final Map<int, Future<void>> _discarding = {};
  Future<int>? _clearing;
  final List<int> _order = <int>[];
  bool _closed = false;
  Future<void> _mutations = Future<void>.value();
  final Map<int, Future<AudioStreamEntry>> _pendingOpens = {};
  int _pendingAcquires = 0;

  /// Acquires a file and pins it within the same cache mutation. Taking a lease
  /// after awaiting open would let a queued eviction win before the reader pins.
  Future<AudioStreamLease> acquire(
    String url, {
    int? expectedBytes,
    bool force = false,
  }) {
    if (_closed) return Future.error(StateError('the audio cache is closed'));
    if (maximumEntries < 1) {
      return Future.error(
        ArgumentError.value(maximumEntries, 'maximumEntries'),
      );
    }
    if (_pendingOpens.length + _pendingAcquires >= maximumEntries) {
      return Future.error(StateError('too many pending audio cache opens'));
    }
    _pendingAcquires++;
    return _serialize(() async {
      final entry = await _open(
        url,
        expectedBytes: expectedBytes,
        force: force,
      );
      if (_closed) throw StateError('the audio cache is closed');
      return entry.retain();
    }).whenComplete(() => _pendingAcquires--);
  }

  /// Opens (or reuses) the cache file for [url] and starts its download.
  ///
  /// The file exists by the time this returns, so the engine's reader can open it
  /// immediately; the bytes arrive afterwards.
  ///
  /// [force] starts a new download even when the cached entry exists — including
  /// one whose download already failed. The fresh entry resumes from the bytes
  /// already on disk, so recovering a dead download does not refetch the part
  /// that did arrive.
  Future<AudioStreamEntry> open(
    String url, {
    int? expectedBytes,
    bool force = false,
  }) {
    if (_closed) return Future.error(StateError('the audio cache is closed'));
    final int key = _cacheKey(url);
    final Future<AudioStreamEntry>? pending = _pendingOpens[key];
    if (pending != null) return pending;
    if (maximumEntries < 1) {
      return Future.error(
        ArgumentError.value(maximumEntries, 'maximumEntries'),
      );
    }
    if (_pendingOpens.length + _pendingAcquires >= maximumEntries) {
      return Future.error(StateError('too many pending audio cache opens'));
    }
    final Future<AudioStreamEntry> result = _serialize(
      () => _open(url, expectedBytes: expectedBytes, force: force),
    );
    _pendingOpens[key] = result;
    void remove() {
      if (identical(_pendingOpens[key], result)) _pendingOpens.remove(key);
    }

    unawaited(
      result.then<void>(
        (_) => remove(),
        onError: (Object _, StackTrace _) => remove(),
      ),
    );
    return result;
  }

  Future<AudioStreamEntry> _open(
    String url, {
    int? expectedBytes,
    bool force = false,
  }) async {
    if (_closed) throw StateError('the audio cache is closed');
    final int key = _cacheKey(url);
    final AudioStreamEntry? existing = _entries[key];
    if (existing != null && !force) {
      if (!existing.complete &&
          !existing.cancelled &&
          existing.failure == null) {
        _touch(key);
        return existing;
      }
      // A finished or cancelled download is restarted from what is on disk.
      existing.expectedBytes ??= expectedBytes;
      if (existing.complete) {
        _touch(key);
        return existing;
      }
    }
    if (existing != null) {
      if (existing.leased) {
        throw StateError('the audio cache file is still in use');
      }
      // Replacing the entry replaces its download too. Leaving the old one alive
      // gave one file two writers that overwrote each other's ranges while the
      // reader was serving it, and kept fetching bytes nobody would use.
      existing.cancel();
      await existing.done;
      _entries.remove(key);
      _order.remove(key);
    }
    await _evict();
    if (_closed) throw StateError('the audio cache is closed');
    final Directory directory = await _directory();
    if (_closed) throw StateError('the audio cache is closed');
    final Directory cacheDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}audio-cache',
    );
    if (!await cacheDirectory.exists()) {
      await cacheDirectory.create(recursive: true);
    }
    final File file = File(
      '${cacheDirectory.path}${Platform.pathSeparator}${_fileName(key)}',
    );
    if (!await file.exists()) await file.create(recursive: true);
    if (_closed) throw StateError('the audio cache is closed');
    final AudioStreamEntry entry = AudioStreamEntry(
      url: url,
      file: file,
      key: key,
      expectedBytes: expectedBytes,
      responseHeaderTimeout: responseHeaderTimeout,
    );
    _entries[key] = entry;
    _order.remove(key);
    _order.add(key);
    await _prunePreviousLaunches(cacheDirectory);
    if (_closed) {
      entry.cancel();
      throw StateError('the audio cache is closed');
    }
    unawaited(entry.download(_client));
    return entry;
  }

  /// Discards a fully downloaded response the decoder rejected as a source.
  /// HTTP 200 can still contain an expired-link HTML/JSON error page. Keeping
  /// that response as a complete audio file makes every later play fail without
  /// contacting the server. Device/format-policy errors must not call this.
  /// Incomplete downloads retain their resumable bytes and normal retry policy.
  Future<void> discardRejectedComplete(AudioStreamEntry entry) {
    if (!entry.complete ||
        entry.leased ||
        !identical(_entries[entry.key], entry)) {
      return Future<void>.value();
    }
    final pending = _discarding[entry.key];
    if (pending != null) return pending;
    late final Future<void> discard;
    discard =
        _serialize(() async {
          // complete is published before the final sink close. Wait for that close
          // before deleting, and make concurrent opens wait for this operation.
          await entry.done;
          if (entry.leased || !identical(_entries[entry.key], entry)) return;
          if (await entry.file.exists()) await entry.file.delete();
          if (identical(_entries[entry.key], entry)) {
            _entries.remove(entry.key);
            _order.remove(entry.key);
          }
        }).whenComplete(() {
          if (identical(_discarding[entry.key], discard)) {
            _discarding.remove(entry.key);
          }
        });
    _discarding[entry.key] = discard;
    return discard;
  }

  /// Deletes every cached file; returns how many were removed.
  Future<int> clear() => _clearing ??= _serialize(_clear).whenComplete(() {
    _clearing = null;
  });

  Future<int> _clear() async {
    for (final AudioStreamEntry entry in _entries.values) {
      entry.cancel();
    }
    await Future.wait(_entries.values.map((entry) => entry.done));
    _entries.clear();
    _order.clear();
    final Directory directory = await _directory();
    final Directory cacheDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}audio-cache',
    );
    if (!await cacheDirectory.exists()) return 0;
    int removed = 0;
    await for (final FileSystemEntity entity in cacheDirectory.list()) {
      try {
        await entity.delete();
        removed++;
      } catch (error) {
        developer.log(
          'could not delete ${entity.path}: $error',
          name: 'lazer-audio',
        );
      }
    }
    return removed;
  }

  /// Stops every download and closes the HTTP client.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final AudioStreamEntry entry in _entries.values) {
      entry.cancel();
    }
    _entries.clear();
    _order.clear();
    _client.close(force: true);
  }

  Future<void> _evict() async {
    while (_order.length >= maximumEntries) {
      final index = _order.indexWhere((key) => _entries[key]?.leased != true);
      if (index < 0) {
        throw StateError('all audio cache files are in use');
      }
      final int oldest = _order.removeAt(index);
      final AudioStreamEntry? entry = _entries.remove(oldest);
      if (entry == null) continue;
      entry.cancel();
      await entry.done;
      try {
        if (await entry.file.exists()) await entry.file.delete();
      } catch (error) {
        developer.log('eviction failed: $error', name: 'lazer-audio');
      }
    }
  }

  void _touch(int key) {
    _order.remove(key);
    _order.add(key);
  }

  /// Files from a previous process are not in [_entries]. Count those too, so
  /// restarting the app cannot add another full cache allowance every time.
  /// Stream the directory and retain only the newest bounded set of candidates.
  Future<void> _prunePreviousLaunches(Directory directory) async {
    final active = _entries.values.map((entry) => entry.file.path).toSet();
    final available = math.max(0, maximumEntries - active.length);
    final retained = <(File, DateTime)>[];
    final cacheName = RegExp(r'^[0-9a-f]{16}\.audio$');
    await for (final entity in directory.list(followLinks: false)) {
      if (_closed) return;
      if (entity is! File || active.contains(entity.path)) continue;
      final name = entity.uri.pathSegments.last;
      if (!cacheName.hasMatch(name)) continue;
      try {
        retained.add((entity, (await entity.stat()).modified));
        retained.sort((a, b) => b.$2.compareTo(a.$2));
        if (retained.length > available) {
          await retained.removeLast().$1.delete();
        }
      } on FileSystemException catch (error) {
        developer.log('cache pruning failed: $error', name: 'lazer-audio');
      }
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final Future<T> result = _mutations.then((_) => operation());
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static String _fileName(int key) =>
      '${key.toRadixString(16).padLeft(16, '0')}.audio';

  /// Stable 64-bit FNV-1a of the URL. Not a security hash: it only needs to name
  /// a cache file consistently between launches.
  static int _cacheKey(String url) {
    int hash = 0xcbf29ce484222325;
    for (final int byte in utf8.encode(url)) {
      hash ^= byte & 0xff;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return math.max(1, hash);
  }
}
