// Growing-file cache for network sources.
//
// The engine cannot open an HTTP URL itself (its C ABI takes a path or a byte
// reader), so streaming works the way the master branch does it: download into a
// cache file while the engine reads it through the bridge's blocking reader. The
// file is the buffer — a read for a byte range that has not landed yet waits for
// the download instead of failing, which is also what makes seek-before-downloaded
// behave like a slow file rather than a short one.
//
// Only the file and the download live here; the reader lifecycle belongs to
// `NativeStreamReader` and the transport to `NativeAudioEngine`.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

/// Supplies the cache directory.
///
/// Injected rather than looked up so this file has no Flutter dependency: the
/// download/resume logic is exercised by plain-Dart checks (`tool/`), which the
/// app-side factory (`engine_factory.dart`) cannot be.
typedef CacheDirectoryProvider = Future<Directory> Function();

/// One cache file plus the download that fills it.
class AudioStreamEntry {
  AudioStreamEntry({
    required this.url,
    required this.file,
    required this.key,
    this.expectedBytes,
  });

  final String url;
  final File file;

  /// Stable 64-bit name derived from the URL; used for the file name so a
  /// re-open resumes the same download across launches.
  final int key;

  int? expectedBytes;

  /// Called when bytes land, so a blocked engine read can wake.
  void Function()? onAppended;

  /// Called once when the download ends, with whether it failed.
  void Function(bool failed)? onFinished;

  int _downloadedBytes = 0;
  bool _complete = false;
  bool _cancelled = false;
  Object? _failure;
  RandomAccessFile? _sink;
  Completer<void>? _done;

  /// Bytes currently readable from the file.
  int get downloadedBytes => _downloadedBytes;

  /// Whether every announced byte arrived.
  bool get complete => _complete;

  /// Why the download stopped, or null while it is running or finished cleanly.
  Object? get failure => _failure;

  bool get cancelled => _cancelled;

  /// Downloaded fraction, 0 when the server never announced a length.
  double get progress {
    if (_complete) return 1;
    final int? total = expectedBytes;
    if (total == null || total <= 0) return 0;
    return (_downloadedBytes / total).clamp(0, 1);
  }

  /// Waits until the download finished, failed or was cancelled.
  Future<void> get done => _done?.future ?? Future<void>.value();

  /// The reader asks for the length, so an announced size is reported even while
  /// the file is still growing; a growing file then looks like a slow source.
  int? get lengthHint => expectedBytes;

  void cancel() {
    if (_cancelled || _complete) return;
    _cancelled = true;
    final Completer<void>? pending = _done;
    if (pending != null && !pending.isCompleted) pending.complete();
    onFinished?.call(true);
    unawaited(_sink?.close().catchError((Object _) => _sink = null));
    _sink = null;
  }

  /// Runs the download to completion. Only `AudioStreamCache` calls this.
  Future<void> download(HttpClient client) async {
    final Completer<void> done = Completer<void>();
    _done = done;
    bool failed = false;
    try {
      await _run(client);
    } catch (error) {
      failed = true;
      _failure = error;
      developer.log('download failed for $url: $error', name: 'lazer-audio');
    } finally {
      await _sink?.close();
      _sink = null;
      if (!done.isCompleted) done.complete();
      onFinished?.call(failed || _cancelled);
    }
  }

  Future<void> _run(HttpClient client) async {
    final bool existed = await file.exists();
    int position = existed ? await file.length() : 0;
    final int? announced = expectedBytes;
    if (announced != null && announced > 0 && position == announced) {
      _downloadedBytes = position;
      _complete = true;
      return;
    }
    if (announced != null && announced > 0 && position > announced) {
      // The file is longer than the track claims to be (a changed variant or a
      // stale partial file): start over rather than resuming past the end.
      _sink = await file.open(mode: FileMode.write);
      position = 0;
    } else {
      _sink = await file.open(mode: FileMode.append);
    }
    _downloadedBytes = position;

    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (position > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$position-');
    }
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException(
        'HTTP ${response.statusCode} while downloading audio',
        uri: Uri.parse(url),
      );
    }
    // A server that ignores the range restarts the body at zero, so the partial
    // file has to be truncated or the bytes would be prepended twice.
    final bool appending = position > 0 && response.statusCode == HttpStatus.partialContent;
    if (position > 0 && !appending) {
      await _sink?.close();
      _sink = await file.open(mode: FileMode.write);
      position = 0;
      _downloadedBytes = 0;
    }
    final int? total = _totalBytes(response, position);
    if (total != null) expectedBytes = total;

    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 20),
    )) {
      if (_cancelled) return;
      if (chunk.isEmpty) continue;
      final RandomAccessFile sink = _sink ??= await file.open(
        mode: FileMode.append,
      );
      sink.writeFromSync(chunk);
      position += chunk.length;
      _downloadedBytes = position;
      onAppended?.call();
    }
    if (_cancelled) return;
    final int? expected = expectedBytes;
    if (expected != null && expected > 0 && position < expected) {
      throw const FileSystemException('audio download ended early');
    }
    _complete = true;
  }

  /// Total size from `Content-Length`, or from `Content-Range` when resuming.
  int? _totalBytes(HttpClientResponse response, int position) {
    final String? range = response.headers.value(HttpHeaders.contentRangeHeader);
    if (range != null) {
      final RegExpMatch? match = RegExp(r'/(\d+)\s*$').firstMatch(range);
      final int? total = match == null ? null : int.tryParse(match.group(1)!);
      if (total != null && total > 0) return total;
    }
    final int length = response.contentLength;
    if (length > 0) return position + length;
    return null;
  }
}

/// Owns the cache directory and the entries that are in use.
class AudioStreamCache {
  /// The directory provider is positional so it can be an initializing formal
  /// (`this._directory`); a named parameter cannot carry a private name.
  AudioStreamCache(
    this._directory, {
    HttpClient? client,
    this.maximumEntries = 8,
  }) : _client =
           client ??
           // Keep-alive client with a bounded connect timeout; `close()` forces
           // it shut. Injectable so a check can drive it.
           (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final CacheDirectoryProvider _directory;
  final HttpClient _client;

  /// How many files are kept on disk; the least recently opened entry is evicted.
  final int maximumEntries;

  final Map<int, AudioStreamEntry> _entries = <int, AudioStreamEntry>{};
  final List<int> _order = <int>[];
  bool _closed = false;

  /// Opens (or reuses) the cache file for [url] and starts its download.
  ///
  /// The file exists by the time this returns, so the engine's reader can open it
  /// immediately; the bytes arrive afterwards.
  Future<AudioStreamEntry> open(String url, {int? expectedBytes}) async {
    if (_closed) throw StateError('the audio cache is closed');
    final int key = _cacheKey(url);
    final AudioStreamEntry? existing = _entries[key];
    if (existing != null) {
      if (!existing.complete && !existing.cancelled) return existing;
      // A finished or cancelled download is restarted from what is on disk.
      existing.expectedBytes ??= expectedBytes;
      if (existing.complete) return existing;
    }
    final Directory directory = await _directory();
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
    final AudioStreamEntry entry = AudioStreamEntry(
      url: url,
      file: file,
      key: key,
      expectedBytes: expectedBytes,
    );
    _entries[key] = entry;
    _order.remove(key);
    _order.add(key);
    await _evict();
    unawaited(entry.download(_client));
    return entry;
  }

  /// Deletes every cached file; returns how many were removed.
  Future<int> clear() async {
    for (final AudioStreamEntry entry in _entries.values) {
      entry.cancel();
    }
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
    while (_order.length > maximumEntries) {
      final int oldest = _order.removeAt(0);
      final AudioStreamEntry? entry = _entries.remove(oldest);
      if (entry == null) continue;
      entry.cancel();
      try {
        if (await entry.file.exists()) await entry.file.delete();
      } catch (error) {
        developer.log('eviction failed: $error', name: 'lazer-audio');
      }
    }
  }

  static String _fileName(int key) =>
      '${key.toRadixString(16).padLeft(16, '0')}.audio';

  /// Stable 64-bit FNV-1a of the URL. Not a security hash: it only needs to name
  /// a cache file consistently between launches.
  static int _cacheKey(String url) {
    int hash = 0xcbf29ce484222325;
    for (final int byte in url.codeUnits) {
      hash ^= byte & 0xff;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return math.max(1, hash);
  }
}
