import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

enum CacheBucket { audio, artwork, data }

/// Disposable, bounded files. Failed/partial writes are never cache hits.
class DiskCache {
  DiskCache({
    Future<Directory> Function()? directory,
    this.limits = const {
      CacheBucket.audio: 1024 * 1024 * 1024,
      CacheBucket.artwork: 256 * 1024 * 1024,
      CacheBucket.data: 64 * 1024 * 1024,
    },
  }) : _directory = directory ?? _defaultDirectory;

  static final shared = DiskCache();
  final Future<Directory> Function() _directory;
  final Map<CacheBucket, int> limits;
  Future<Directory?>? _root;
  final _writes = <String, Future<File?>>{};
  final _maintenance = <CacheBucket, Future<void>>{};
  final _pruneRequested = <CacheBucket, Uri>{};
  final Map<String, Future<void>> _jsonOperations = <String, Future<void>>{};
  int _serial = 0;

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationCacheDirectory()).path}/lazer_cache_v1',
  );

  Future<Directory?> _open() => _root ??= () async {
    try {
      return await (await _directory()).create(recursive: true);
    } catch (_) {
      // A missing/unwritable cache must not prevent streaming or API access.
      return null;
    }
  }();

  Future<File?> _path(CacheBucket bucket, String key, String extension) async {
    final root = await _open();
    if (root == null) return null;
    final dir = await Directory(
      '${root.path}/${bucket.name}',
    ).create(recursive: true);
    final hash = sha256.convert(utf8.encode(key));
    return File('${dir.path}/$hash.$extension');
  }

  Future<File?> find(
    CacheBucket bucket,
    String key, {
    String extension = 'bin',
  }) async {
    try {
      final file = await _path(bucket, key, extension);
      if (file == null || !await file.exists() || await file.length() == 0) {
        return null;
      }
      await file.setLastModified(DateTime.now());
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(
    CacheBucket bucket,
    String key, {
    String extension = 'bin',
  }) {
    if (bucket == CacheBucket.data && extension == 'json') {
      return _jsonOperation(key, () => _remove(bucket, key, extension));
    }
    return _remove(bucket, key, extension);
  }

  Future<void> _remove(CacheBucket bucket, String key, String extension) async {
    try {
      final file = await _path(bucket, key, extension);
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Coalesces concurrent writers, streams to a temporary file, then commits.
  Future<File?> put(
    CacheBucket bucket,
    String key,
    Stream<List<int>> Function() source, {
    String extension = 'bin',
    int? expectedLength,
    int? maxBytes,
  }) {
    final identity = '${bucket.name}:$key:$extension';
    final pending = _writes[identity];
    if (pending != null) return pending;
    final future = _put(
      bucket,
      key,
      source,
      extension,
      expectedLength,
      maxBytes,
    );
    _writes[identity] = future;
    unawaited(future.whenComplete(() => _writes.remove(identity)));
    return future;
  }

  Future<File?> _put(
    CacheBucket bucket,
    String key,
    Stream<List<int>> Function() source,
    String extension,
    int? expectedLength,
    int? maxBytes,
  ) async {
    File? partial;
    IOSink? sink;
    try {
      final target = await _path(bucket, key, extension);
      if (target == null) return null;
      final budget = limits[bucket] ?? 0;
      final ceiling = maxBytes == null
          ? budget
          : (maxBytes < budget ? maxBytes : budget);
      if (ceiling <= 0 || (expectedLength ?? 0) > ceiling) return null;
      partial = File('${target.path}.${_serial++}.part');
      sink = partial.openWrite();
      // Observe disk failures immediately while the network stream is active.
      final done = sink.done.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      var length = 0;
      await for (final chunk in source()) {
        length += chunk.length;
        if (length > ceiling) {
          throw const FileSystemException('Cache entry too large');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final failure = await done;
      if (failure != null) throw failure;
      if (length == 0 ||
          (expectedLength != null &&
              expectedLength >= 0 &&
              length != expectedLength)) {
        throw const FileSystemException('Incomplete cache entry');
      }
      await partial.rename(target.path);
      partial = null;
      _schedulePrune(bucket, target.uri);
      return target;
    } catch (_) {
      return null;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (_) {}
    }
  }

  void _schedulePrune(CacheBucket bucket, Uri keep) {
    _pruneRequested[bucket] = keep;
    _maintenance.putIfAbsent(bucket, () => _maintain(bucket));
  }

  Future<void> _maintain(CacheBucket bucket) async {
    try {
      while (_pruneRequested.containsKey(bucket)) {
        // A shelf can finish dozens of cover downloads together. Share one
        // scan per burst, including writes arriving while a scan is active.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final keep = _pruneRequested.remove(bucket)!;
        await _prune(bucket, keep);
      }
    } finally {
      _maintenance.remove(bucket);
    }
  }

  Future<void> _prune(CacheBucket bucket, Uri keep) async {
    try {
      final root = await _open();
      if (root == null) return;
      final files = <(File, FileStat)>[];
      var total = 0;
      await for (final entry in Directory(
        '${root.path}/${bucket.name}',
      ).list()) {
        if (entry is! File) continue;
        final stat = await entry.stat();
        if (entry.path.endsWith('.part')) {
          if (DateTime.now().difference(stat.modified) >
              const Duration(days: 1)) {
            await entry.delete();
          }
          continue;
        }
        files.add((entry, stat));
        total += stat.size;
      }
      final budget = limits[bucket] ?? 0;
      if (total <= budget) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in files) {
        if (total <= budget) break;
        if (file.uri == keep || file.uri == _pruneRequested[bucket]) continue;
        try {
          await file.delete();
          total -= stat.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Waits for queued LRU maintenance. Tests and shutdown paths only; normal
  /// callers must not block on a bucket scan.
  Future<void> settle() async {
    while (_maintenance.isNotEmpty) {
      await Future.wait(_maintenance.values.toList());
    }
  }

  // Reads, replacement writes and invalidations for a key must be ordered.
  // Generic [put] coalesces downloads; JSON updates instead need every new
  // value (including a tombstone) to follow the previous operation.
  Future<T> _jsonOperation<T>(String key, Future<T> Function() action) {
    final Future<void> previous = _jsonOperations[key] ?? Future<void>.value();
    final Future<T> result = previous.then((_) => action());
    final Future<void> completion = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    _jsonOperations[key] = completion;
    unawaited(
      completion.whenComplete(() {
        if (identical(_jsonOperations[key], completion)) {
          _jsonOperations.remove(key);
        }
      }),
    );
    return result;
  }

  Future<CachedJson?> readJson(String key) =>
      _jsonOperation(key, () => _readJson(key));

  Future<CachedJson?> _readJson(String key) async {
    try {
      final file = await find(CacheBucket.data, key, extension: 'json');
      if (file == null) return null;
      final raw = await file.readAsString();
      return raw.length < 65536
          ? _decodeCachedJson(raw)
          : await compute(
              _decodeCachedJson,
              raw,
              debugLabel: 'cache-json-decode',
            );
    } catch (_) {
      await _remove(CacheBucket.data, key, 'json');
      return null;
    }
  }

  /// Expire a snapshot without losing its offline fallback.
  Future<void> expireJson(String key) => _jsonOperation(key, () async {
    final saved = await _readJson(key);
    if (saved != null) {
      final data = <String, dynamic>{'savedAt': 0, 'data': saved.data};
      final bytes = _isLargeJson(data)
          ? await compute(
              _encodeCachedJson,
              data,
              debugLabel: 'cache-json-encode',
            )
          : _encodeCachedJson(data);
      await _writeJsonBytes(key, bytes);
    }
  });

  /// Captures the supplied data at invocation, then writes it after any
  /// earlier operation for the same key. Large payloads are encoded off the
  /// UI isolate after taking a detached snapshot.
  Future<void> writeJson(
    String key,
    Map<String, dynamic> data, {
    DateTime? savedAt,
  }) {
    try {
      final envelope = <String, dynamic>{
        'savedAt': (savedAt ?? DateTime.now()).millisecondsSinceEpoch,
        'data': data,
      };
      if (!_isLargeJson(envelope)) {
        final bytes = _encodeCachedJson(envelope);
        return _jsonOperation(key, () => _writeJsonBytes(key, bytes));
      }
      final snapshot =
          _copyJson(envelope, Map<Object, Object>.identity())
              as Map<String, dynamic>;
      return _jsonOperation(key, () async {
        final bytes = await compute(
          _encodeCachedJson,
          snapshot,
          debugLabel: 'cache-json-encode',
        );
        await _writeJsonBytes(key, bytes);
      });
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
  }

  Future<void> _writeJsonBytes(String key, List<int> bytes) async {
    await put(
      CacheBucket.data,
      key,
      () => Stream.value(bytes),
      extension: 'json',
    );
  }
}

class CachedJson {
  const CachedJson(this.data, this.savedAt);
  final Map<String, dynamic> data;
  final DateTime savedAt;
  bool fresh(Duration ttl) => DateTime.now().difference(savedAt) < ttl;

  /// [DiskCache.expireJson] keeps the payload as an offline fallback but
  /// stamps it with the Unix epoch. Cache-first readers must treat that copy
  /// as gone: it can predate the mutation that forced the refresh.
  bool get invalidated => savedAt.millisecondsSinceEpoch == 0;
}

CachedJson _decodeCachedJson(String raw) {
  final value = jsonDecode(raw) as Map<String, dynamic>;
  return CachedJson(
    value['data'] as Map<String, dynamic>,
    DateTime.fromMillisecondsSinceEpoch(value['savedAt'] as int),
  );
}

List<int> _encodeCachedJson(Map<String, dynamic> data) =>
    utf8.encode(jsonEncode(data));

// A short bounded walk keeps small snapshots on the cheap synchronous path.
// Large collections and long strings move JSON serialization off-thread.
bool _isLargeJson(Object? value) {
  var remaining = 256;
  bool visit(Object? item) {
    if (--remaining < 0) return true;
    if (item is String) return item.length >= 65536;
    if (item is List) {
      if (item.length >= 128) return true;
      return item.any(visit);
    }
    if (item is Map) {
      if (item.length >= 128) return true;
      return item.values.any(visit);
    }
    return false;
  }

  return visit(value);
}

// Detach ordinary JSON containers before a queued encode; preserve identity
// so jsonEncode still rejects cyclic input instead of recursing indefinitely.
Object? _copyJson(Object? value, Map<Object, Object> seen) {
  if (value is List) {
    final existing = seen[value];
    if (existing != null) return existing;
    final copy = <dynamic>[];
    seen[value] = copy;
    for (final item in value) {
      copy.add(_copyJson(item, seen));
    }
    return copy;
  }
  if (value is Map) {
    final existing = seen[value];
    if (existing != null) return existing;
    if (value is Map<String, dynamic>) {
      final copy = <String, dynamic>{};
      seen[value] = copy;
      value.forEach((key, item) => copy[key] = _copyJson(item, seen));
      return copy;
    }
    final copy = <dynamic, dynamic>{};
    seen[value] = copy;
    value.forEach((key, item) => copy[key] = _copyJson(item, seen));
    return copy;
  }
  return value;
}
