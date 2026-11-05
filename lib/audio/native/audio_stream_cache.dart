// Growing-file cache for network sources.
//
// The engine cannot open an HTTP URL itself (its C ABI takes a path or a byte
// reader), so streaming works the way the master branch does it: download into a
// cache file while the engine reads it through the bridge's blocking reader.
//
// The file is the buffer, and it does not have to be a prefix. A seek into a part
// of the track the linear download has not reached makes the download restart its
// request at that byte offset (`Range:`) and append what it fetches to the cache
// file, so the engine reads the region it asked for instead of waiting for a
// whole linear pass. That leaves the file holding two ranges of the *track*:
//
//   [0, prefixEnd)                     at file offset 0
//   [windowStart, windowEnd)           at file offset windowFileStart
//
// with a gap between them that nobody wrote. The entry publishes both ranges to
// the reader (which maps a track offset to a file offset through
// `lazer_bridge_reader_set_window`) and answers a demand for a byte in the gap by
// fetching it, so a gap is never served as silence.
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
  void Function(bool finished)? onFinished;

  /// Called whenever the written ranges move, so the reader can be told which
  /// track offsets it may serve without waiting.
  void Function()? onRangeChanged;

  /// How much of the track is fetched *before* a seek target, so a demuxer that
  /// steps back to a frame boundary finds its bytes already in the window.
  static const int seekPrerollBytes = 512 * 1024;

  /// How far past the downloaded window a read may ask for bytes before the
  /// download is redirected. A read at the frontier is the ordinary streaming
  /// case (the running download is about to deliver it); a read well past it is
  /// a demuxer jumping somewhere, which is worth a fresh request.
  static const int frontierSlackBytes = 1024 * 1024;

  /// A reader can attach after the HTTP response already finished. Replay the
  /// current state so its first blocking read never waits for a lost event.
  void bindReader({
    required void Function() appended,
    required void Function(bool failed) finished,
    void Function()? ranges,
  }) {
    onAppended = appended;
    onFinished = finished;
    onRangeChanged = ranges;
    appended();
    onRangeChanged?.call();
    if (complete || _cancelled || _failure != null) finished(!complete);
  }

  int _downloadedBytes = 0;
  bool _cancelled = false;
  bool _allBytesPresent = false;
  bool _rangeSupported = true;
  Object? _failure;
  RandomAccessFile? _sink;
  HttpClient? _client;
  Completer<void>? _done;

  /// The range written from byte zero, contiguous by construction.
  int _prefixEnd = 0;

  /// The range a redirected download is filling, in track coordinates, and where
  /// it starts in the file. [_windowMapped] is false while the download is the
  /// plain linear one, whose bytes run to the end of the file.
  int _windowStart = 0;
  int _windowEnd = 0;
  int _windowFileStart = 0;
  bool _windowMapped = false;

  /// Bytes written by the response being read.
  int _windowWritten = 0;

  /// A redirect asked for while a response was being read. The download loop
  /// abandons the body and restarts at this offset.
  int? _pendingWindowStart;
  Completer<void>? _redirectApplied;

  /// The body of the window being written, and the completion of that write.
  StreamSubscription<List<int>>? _body;
  Completer<bool>? _bodyDone;

  /// Completed once the track's size is known or provably unknowable (the body
  /// started arriving without a `Content-Length`), so a caller can wait for the
  /// one fact a demuxer needs before it opens the source.
  final Completer<void> _lengthResolved = Completer<void>();

  /// When the download last moved, for the stall report. Set on every chunk and
  /// on every wait, so a reader can tell "slow" from "dead".
  DateTime _lastProgressAt = DateTime.now();

  /// Bytes of the track currently readable from the file.
  int get downloadedBytes => _downloadedBytes;

  /// End (exclusive) of the range written from byte zero.
  int get prefixEnd => _prefixEnd;

  /// Start of the range a redirected download is filling.
  int get windowStart => _windowStart;

  /// End (exclusive) of that range, or [prefixEnd] while the download is the
  /// plain linear one.
  int get windowEnd => _windowMapped ? _windowEnd : _prefixEnd;

  /// Where the window's first byte sits in the file.
  int get windowFileStart => _windowFileStart;

  /// Whether the window is a redirected segment rather than the linear tail.
  bool get windowMapped => _windowMapped;

  /// False once the server has been seen ignoring a `Range` request: the cache
  /// then only ever grows linearly, and a seek past the download cannot be
  /// served until the linear pass gets there.
  bool get rangeSupported => _rangeSupported;

  /// Whether every byte of the track is on disk, in one run without a gap.
  ///
  /// This is what lets the reader end the stream; a file that holds the whole
  /// track except a gap is *not* complete, because the gap still has to be
  /// fetched on demand.
  bool get complete {
    final int? total = _totalLength;
    if (total != null && _prefixEnd >= total) return true;
    if (!_allBytesPresent) return false;
    if (total == null) return !_windowMapped || _windowStart <= _prefixEnd;
    // Everything arrived, and the appended window closes the track's tail.
    return _windowMapped && _windowStart <= _prefixEnd && windowEnd >= total;
  }

  int? get _totalLength {
    final int? total = expectedBytes;
    return total != null && total > 0 ? total : null;
  }

  /// Whether the download stopped, or null while it is running or finished cleanly.
  Object? get failure => _failure;

  bool get cancelled => _cancelled;

  /// Whether the server announced a total size. When it did not, [progress] is
  /// unmeasurable rather than zero: the bytes are still arriving.
  bool get lengthKnown => (expectedBytes ?? 0) > 0;

  /// Whether the download has neither moved for [threshold] nor finished.
  ///
  /// A response that trickles a byte per minute still resets this, which is the
  /// honest answer: bytes are arriving, just slowly.
  bool stalledFor(Duration threshold, {DateTime? now}) {
    if (_allBytesPresent || _cancelled || _failure != null) return false;
    return (now ?? DateTime.now()).difference(_lastProgressAt) >= threshold;
  }

  /// Downloaded fraction, or null when the server never announced a length.
  ///
  /// Returning null keeps "cannot be measured" apart from "nothing landed": a
  /// caller that treats an unmeasurable stream as 0 % hides a fully downloaded
  /// chunked response behind an empty buffer bar, and one that treats it as
  /// 100 % lets the seek rail run past what the reader can actually serve.
  double? get progress {
    if (complete) return 1;
    final int? total = _totalLength;
    if (total == null) return null;
    return (_downloadedBytes / total).clamp(0, 1);
  }

  /// Waits until the download finished, failed or was cancelled.
  Future<void> get done => _done?.future ?? Future<void>.value();

  /// The reader asks for the length, so an announced size is reported even while
  /// the file is still growing; a growing file then looks like a slow source.
  int? get lengthHint => expectedBytes;

  /// Exclusive end of the readable range that contains [offset], or -1 when the
  /// offset is in the gap between the prefix and the window.
  int readableEndAt(int offset) {
    if (offset < _prefixEnd) return _prefixEnd;
    final int end = windowEnd;
    if (_windowMapped && offset >= _windowStart && offset < end) return end;
    return -1;
  }

  /// Fetches the bytes around [offset] when the cache does not hold them.
  ///
  /// The reader calls this on a demand: the engine's decoder is parked on a byte
  /// that is neither in the written prefix nor in the window. `seek` marks a
  /// demand that came from a seek, which is always worth a fresh request; a read
  /// just past the frontier is the ordinary streaming case and must not restart
  /// the download it is already waiting for.
  Future<void> ensureRange(int offset, {required bool seek}) async {
    if (offset < 0 || _cancelled || _failure != null) return;
    if (readableEndAt(offset) > offset) return;
    if (_allBytesPresent || !_rangeSupported) return;
    final int? total = _totalLength;
    if (total != null && offset >= total) return;
    final int end = windowEnd;
    // A read at (or just past) the frontier is the ordinary streaming case: the
    // running download is about to deliver it. Only a demand that is well beyond
    // it — a demuxer jumping somewhere — is worth a fresh request.
    if (!seek && offset >= end && offset - end <= frontierSlackBytes) return;
    final int start = math.max(0, offset - seekPrerollBytes);
    if (_windowMapped && start >= _windowStart && start < end) {
      // The running download is already fetching this neighbourhood.
      return;
    }
    await _redirect(start);
  }

  /// Waits for the download to announce the track's size, or for [timeout].
  ///
  /// A demuxer needs the source length to turn a seek's timestamp into a byte
  /// offset, and the size arrives with the response headers — later than the
  /// point the engine creates its reader. Returns the size when it is known, and
  /// null when the server never announced one (the body has already started, so
  /// waiting longer would only delay playback).
  Future<int?> expectedLengthWithin(Duration timeout) async {
    final int? known = expectedBytes;
    if (known != null && known > 0) return known;
    if (_done == null || _lengthResolved.isCompleted || _cancelled || _failure != null) {
      // Nothing is downloading, so there is no announcement to wait for.
      return expectedBytes;
    }
    await _lengthResolved.future.timeout(
      timeout,
      onTimeout: () => _resolveLength(),
    );
    return expectedBytes;
  }

  void _resolveLength() {
    if (!_lengthResolved.isCompleted) _lengthResolved.complete();
  }

  void cancel() {
    if (_cancelled || _allBytesPresent) return;
    _cancelled = true;
    _unblockRedirect();
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
    _client = client;
    bool failed = false;
    try {
      await _run();
    } catch (error) {
      failed = true;
      _failure = error;
      developer.log('download failed for $url: $error', name: 'lazer-audio');
    } finally {
      await _sink?.close();
      _sink = null;
      if (!done.isCompleted) done.complete();
      // Nobody should keep waiting for a size that is not coming.
      _resolveLength();
      onFinished?.call(failed || _cancelled);
    }
  }

  Future<void> _run() async {
    await _resumeFromDisk();
    if (_allBytesPresent) return;
    while (!_cancelled) {
      final int? pending = _pendingWindowStart;
      final bool reachedEnd = await _downloadWindow(
        pending ?? _windowStart,
        // A pending redirect always starts a fresh segment; continuing the file
        // is the plain linear pass.
        mapped: pending != null,
      );
      if (_cancelled) return;
      if (!reachedEnd) continue;
      _allBytesPresent = true;
      _lastProgressAt = DateTime.now();
      if (complete) await _deleteMarker();
      return;
    }
  }

  /// Picks up whatever a previous launch left in the cache file.
  ///
  /// A redirected download appends its bytes after the prefix, and those bytes
  /// belong to another part of the track: the marker records where the prefix
  /// ends so the segments of an earlier session are dropped instead of being
  /// mistaken for the track's beginning.
  Future<void> _resumeFromDisk() async {
    final bool existed = await file.exists();
    final int length = existed ? await file.length() : 0;
    final int? announced = _totalLength;
    if (announced != null && length >= announced) {
      _downloadedBytes = length;
      _prefixEnd = math.min(length, announced);
      _allBytesPresent = true;
      _resolveLength();
      return;
    }
    final int? marked = await _readMarker();
    if (marked != null && marked < length) {
      // Drop the appended segments: they are not the track's prefix.
      final RandomAccessFile handle = await file.open(mode: FileMode.append);
      try {
        await handle.truncate(marked);
      } finally {
        await handle.close();
      }
      _prefixEnd = marked;
    } else {
      _prefixEnd = length;
    }
    _windowStart = _prefixEnd;
    _windowEnd = _prefixEnd;
    _windowFileStart = _prefixEnd;
    _windowMapped = false;
    _downloadedBytes = _prefixEnd;
    if (_prefixEnd > 0 && announced == null) {
      // A cache file left by a previous launch is its own length; the entry was
      // re-opened without the size the provider passed the first time.
      expectedBytes = _prefixEnd;
    }
    await _deleteMarker();
  }

  /// Runs one HTTP request writing the track from [start], appending its body to
  /// the cache file. [mapped] marks a redirected window, whose bytes belong to
  /// [start] rather than continuing the prefix.
  ///
  /// Returns true when the body ended at the end of the track, false when a
  /// redirect interrupted it (the caller loops with the new window start).
  Future<bool> _downloadWindow(int start, {required bool mapped}) async {
    final HttpClient? client = _client;
    if (client == null) throw StateError('the audio cache has no HTTP client');
    _windowStart = start;
    _windowEnd = start;
    _windowMapped = mapped;
    _windowWritten = 0;
    _pendingWindowStart = null;
    await _openSink();
    _notifyRanges();
    // The demand that asked for this window can stop waiting: the download is
    // now fetching the bytes it needs.
    _unblockRedirect();

    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    // Asking for a range from the start tells us whether the server honours one
    // at all; a server that answers 200 keeps the plain linear download.
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException(
        'HTTP ${response.statusCode} while downloading audio',
        uri: Uri.parse(url),
      );
    }
    final bool ranged = response.statusCode == HttpStatus.partialContent;
    if (!ranged) _rangeSupported = false;
    if (start > 0 && !ranged) {
      // The server ignores the range and restarts the body at zero. Nothing it
      // sends can be appended where the prefix is, so the file is rewritten from
      // the start instead of holding the same bytes twice.
      _rangeSupported = false;
      await _sink?.truncate(0);
      _windowStart = 0;
      _windowEnd = 0;
      _windowFileStart = 0;
      _windowMapped = false;
      _windowWritten = 0;
      _prefixEnd = 0;
      _downloadedBytes = 0;
      _notifyRanges();
    }
    final int? total = _totalBytes(response, _windowStart);
    if (total != null) {
      expectedBytes = total;
      _resolveLength();
    }

    final bool reachedEnd = await _pumpBody(response);
    if (reachedEnd) {
      final int? expected = _totalLength;
      if (expected != null && windowEnd < expected) {
        throw const FileSystemException('audio download ended early');
      }
    }
    return reachedEnd;
  }

  /// Writes the response body into the file, stopping early when a redirect
  /// arrives. Returns true when the whole body was consumed.
  Future<bool> _pumpBody(HttpClientResponse response) {
    final Completer<bool> finished = Completer<bool>();
    _bodyDone = finished;
    void complete(bool value) {
      if (!finished.isCompleted) finished.complete(value);
    }

    late StreamSubscription<List<int>> subscription;
    subscription = response
        .timeout(const Duration(seconds: 20))
        .listen(
          (List<int> chunk) {
            if (_cancelled || _pendingWindowStart != null) {
              // A demand arrived for a region this request cannot reach, or the
              // track is gone: drop the body and let the loop move on.
              unawaited(subscription.cancel());
              complete(false);
              return;
            }
            if (chunk.isEmpty) return;
            // Body bytes without a response length: the server never announced a
            // total, so nothing is gained by waiting for one.
            _resolveLength();
            final RandomAccessFile? sink = _sink;
            if (sink == null) return;
            sink.writeFromSync(chunk);
            _windowWritten += chunk.length;
            if (_windowMapped) {
              _windowEnd = _windowStart + _windowWritten;
            } else {
              // The linear download's bytes continue the track from byte zero.
              _prefixEnd = _windowFileStart + _windowWritten;
            }
            _downloadedBytes = math.max(_downloadedBytes, windowEnd);
            _lastProgressAt = DateTime.now();
            onAppended?.call();
          },
          onError: (Object error, StackTrace stack) {
            complete(false);
            if (!finished.isCompleted) finished.completeError(error, stack);
          },
          onDone: () => complete(true),
          cancelOnError: true,
        );
    _body = subscription;
    return finished.future.whenComplete(() {
      if (identical(_bodyDone, finished)) {
        _body = null;
        _bodyDone = null;
      }
    });
  }

  /// Abandons the running request in favour of a window at [start].
  Future<void> _redirect(int start) async {
    final int? total = _totalLength;
    final int target = total == null ? start : math.min(start, math.max(0, total - 1));
    if (_windowMapped && target == _windowStart && _windowWritten == 0) return;
    // The appended body belongs to another part of the track, so the prefix is
    // frozen where the linear pass stopped, and the marker records that before
    // the new segment is written.
    if (!_windowMapped) _prefixEnd = _windowFileStart + _windowWritten;
    _pendingWindowStart = target;
    await _persistMarker();
    final Completer<void> applied = _redirectApplied ??= Completer<void>();
    final Completer<bool>? body = _bodyDone;
    if (body != null && !body.isCompleted) body.complete(false);
    await _body?.cancel();
    // The loop itself is the only writer: wait for it to open the new segment so
    // the next demand sees a consistent range instead of racing this one.
    await applied.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  void _unblockRedirect() {
    final Completer<void>? applied = _redirectApplied;
    _redirectApplied = null;
    if (applied != null && !applied.isCompleted) applied.complete();
  }

  /// Opens the file for appending and records where this window starts in it.
  Future<void> _openSink() async {
    await _sink?.close();
    final RandomAccessFile sink = await file.open(mode: FileMode.append);
    _windowFileStart = await sink.length();
    _sink = sink;
  }

  void _notifyRanges() {
    _downloadedBytes = math.max(_downloadedBytes, windowEnd);
    onRangeChanged?.call();
  }

  /// Total size from `Content-Length`, or from `Content-Range` when resuming.
  int? _totalBytes(HttpClientResponse response, int start) {
    final String? range = response.headers.value(
      HttpHeaders.contentRangeHeader,
    );
    if (range != null) {
      final RegExpMatch? match = RegExp(r'/(\d+)\s*$').firstMatch(range);
      final int? total = match == null ? null : int.tryParse(match.group(1)!);
      if (total != null && total > 0) return total;
    }
    final int length = response.contentLength;
    if (length > 0) return start + length;
    return null;
  }

  /// The marker records where the contiguous prefix ends once a download has
  /// been redirected, because the file then also holds bytes from elsewhere in
  /// the track.
  File get _markerFile => File('${file.path}.head');

  Future<void> _persistMarker() async {
    try {
      await _markerFile.writeAsString('$_prefixEnd', flush: true);
    } catch (error) {
      developer.log('writing the cache marker failed: $error', name: 'lazer-audio');
    }
  }

  Future<int?> _readMarker() async {
    try {
      if (!await _markerFile.exists()) return null;
      return int.tryParse((await _markerFile.readAsString()).trim());
    } catch (error) {
      developer.log('reading the cache marker failed: $error', name: 'lazer-audio');
      return null;
    }
  }

  Future<void> _deleteMarker() async {
    try {
      if (await _markerFile.exists()) await _markerFile.delete();
    } catch (error) {
      developer.log('removing the cache marker failed: $error', name: 'lazer-audio');
    }
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
  ///
  /// [force] starts a new download even when the cached entry exists — including
  /// one whose download already failed. The fresh entry resumes from the bytes
  /// already on disk, so recovering a dead download does not refetch the part
  /// that did arrive.
  Future<AudioStreamEntry> open(
    String url, {
    int? expectedBytes,
    bool force = false,
  }) async {
    if (_closed) throw StateError('the audio cache is closed');
    final int key = _cacheKey(url);
    final AudioStreamEntry? existing = _entries[key];
    if (existing != null && !force) {
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
        final File marker = File('${entry.file.path}.head');
        if (await marker.exists()) await marker.delete();
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
