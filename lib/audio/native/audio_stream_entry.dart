// One growing-file download, owned by AudioStreamCache.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import '../../utils/media_requests.dart';

/// One cache file plus the download that fills it.
class AudioStreamEntry {
  AudioStreamEntry({
    required this.url,
    required this.file,
    required this.key,
    this.expectedBytes,
    this.responseHeaderTimeout = const Duration(seconds: 20),
  });

  final String url;
  final File file;

  /// How long the server may take to send response headers before this download
  /// is abandoned. Configurable so a check can prove the timeout without
  /// spending twenty seconds on it.
  final Duration responseHeaderTimeout;

  /// Stable 64-bit name derived from the URL; used for the file name so a
  /// re-open resumes the same download across launches.
  final int key;

  int? expectedBytes;

  /// Called when bytes land, so a blocked engine read can wake.
  void Function()? onAppended;

  /// Called once when the download ends, with whether it failed.
  void Function(bool failed)? onFinished;

  /// Called when the track's total size becomes known, so the reader can report it
  /// to the engine's demuxer.
  void Function()? onLengthKnown;

  final Set<AudioStreamLease> _leases = {};
  static const maximumReaders = 8;

  /// Readers pin both the growing file and its writer until native releases it.
  bool get leased => _leases.isNotEmpty;

  AudioStreamLease retain() {
    if (_leases.length >= maximumReaders) {
      throw StateError('too many readers of one audio cache file');
    }
    final lease = AudioStreamLease._(this);
    _leases.add(lease);
    return lease;
  }

  /// Retiring one reader must not cancel another reader of the same URL.
  void cancelIfUnleased() {
    if (!leased) cancel();
  }

  void _notifyAppended() {
    onAppended?.call();
    for (final lease in _leases.toList(growable: false)) {
      if (!lease._released) lease._appended?.call();
    }
  }

  void _notifyLengthKnown() {
    onLengthKnown?.call();
    for (final lease in _leases.toList(growable: false)) {
      if (!lease._released) lease._lengthKnown?.call();
    }
  }

  /// A reader can attach after the HTTP response already finished. Replay the
  /// current state so its first blocking read never waits for a lost event.
  void bindReader({
    required void Function() appended,
    required void Function(bool failed) finished,
  }) {
    onAppended = appended;
    onFinished = finished;
    appended();
    onLengthKnown?.call();
    if (_complete || _cancelled || _failure != null) finished(!_complete);
  }

  int _downloadedBytes = 0;
  bool _complete = false;
  bool _cancelled = false;
  Object? _failure;
  RandomAccessFile? _sink;
  HttpClientRequest? _request;
  StreamIterator<List<int>>? _body;
  bool _finishedNotified = false;
  Completer<void>? _done;

  /// When the download last moved, for the stall report. Set on every chunk and
  /// on every wait, so a reader can tell "slow" from "dead".
  DateTime _lastProgressAt = DateTime.now();

  /// Completed once the track's size is known or provably unknowable (the body
  /// started arriving without a `Content-Length`), so a caller can wait for the
  /// one fact a demuxer needs before it opens the source.
  final Completer<void> _lengthResolved = Completer<void>();

  /// Bytes currently readable from the file.
  int get downloadedBytes => _downloadedBytes;

  /// Whether every announced byte arrived.
  bool get complete => _complete;

  /// Why the download stopped, or null while it is running or finished cleanly.
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
    if (_complete || _cancelled || _failure != null) return false;
    return (now ?? DateTime.now()).difference(_lastProgressAt) >= threshold;
  }

  /// Downloaded fraction, or null when the server never announced a length.
  ///
  /// Returning null keeps "cannot be measured" apart from "nothing landed": a
  /// caller that treats an unmeasurable stream as 0 % hides a fully downloaded
  /// chunked response behind an empty buffer bar, and one that treats it as
  /// 100 % lets the seek rail run past what the reader can actually serve.
  double? get progress {
    if (_complete) return 1;
    final int? total = expectedBytes;
    if (total == null || total <= 0) return null;
    return (_downloadedBytes / total).clamp(0, 1);
  }

  /// Waits until the download finished, failed or was cancelled.
  Future<void> get done => _done?.future ?? Future<void>.value();

  /// The reader asks for the length, so an announced size is reported even while
  /// the file is still growing; a growing file then looks like a slow source.
  int? get lengthHint => expectedBytes;

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
    if (_done == null ||
        _lengthResolved.isCompleted ||
        _cancelled ||
        _failure != null) {
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
    if (_lengthResolved.isCompleted) return;
    _lengthResolved.complete();
    _notifyLengthKnown();
  }

  /// Reports a size the response announced, whether or not the wait for it is still running.
  ///
  /// [_resolveLength] latches, so a caller that stopped waiting before the headers arrived would
  /// otherwise never hear about the size at all.
  void _announceLength() {
    if (!_lengthResolved.isCompleted) _lengthResolved.complete();
    _notifyLengthKnown();
  }

  void cancel() {
    if (_cancelled || _complete) return;
    _cancelled = true;
    _resolveLength();
    _request?.abort();
    // abort() alone does not stop a response whose headers already arrived.
    // Cancel the body subscription too, so a stalled CDN cannot hold a reopen
    // behind its idle timeout.
    unawaited(_body?.cancel());
    _notifyFinished(true);
    // The download closes its own sink after any outstanding asynchronous
    // write. done completes only then, so a reopen cannot create two writers.
  }

  void _notifyFinished(bool failed) {
    if (_finishedNotified) return;
    _finishedNotified = true;
    onFinished?.call(failed);
    for (final lease in _leases.toList(growable: false)) {
      if (!lease._released) lease._finished?.call(failed);
    }
  }

  /// Runs the download to completion. Only AudioStreamCache calls this.
  Future<void> download(HttpClient client) async {
    final Completer<void> done = Completer<void>();
    _done = done;
    try {
      if (!_cancelled) await _run(client);
    } catch (error) {
      if (!_cancelled) {
        _failure = error;
        developer.log('audio download failed: $error', name: 'lazer-audio');
      }
    } finally {
      await _body?.cancel();
      _body = null;
      try {
        await _sink?.close();
      } catch (error) {
        if (!_cancelled) {
          _complete = false;
          _failure ??= error;
        }
      }
      _sink = null;
      if (!_complete) _request?.abort();
      _request = null;
      _resolveLength();
      _notifyFinished(_failure != null || _cancelled);
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> _run(HttpClient client) async {
    final bool existed = await file.exists();
    int position = existed ? await file.length() : 0;
    final int? announced = expectedBytes;
    if (announced != null && announced > 0 && position == announced) {
      _downloadedBytes = position;
      _complete = true;
      _lastProgressAt = DateTime.now();
      _resolveLength();
      return;
    }
    if (_cancelled) return;
    // A cache file left by a previous launch is a resume hint, never the track's size: it is exactly
    // as long as the last session got. Publishing its length as `expectedBytes` told the demuxer the
    // song ended there — the reader returns EOF at that byte count — and made `progress` report a
    // partial file as fully downloaded. The size is filled in below, from the response or from a
    // server that says the range is already satisfied.
    if (announced != null && announced > 0 && position > announced) {
      // The file is longer than the track claims to be (a changed variant or a
      // stale partial file): start over rather than resuming past the end.
      _sink = await file.open(mode: FileMode.write);
      position = 0;
    } else {
      _sink = await file.open(mode: FileMode.append);
    }
    _downloadedBytes = position;
    if (_cancelled) return;

    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    // Cancellation may win while getUrl is still connecting. abort completes
    // done with an error even when this branch never reaches request.close().
    unawaited(
      request.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _request = request;
    if (_cancelled) {
      request.abort();
      return;
    }
    MediaRequestRules.headers(url).forEach(request.headers.set);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (position > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$position-');
    }
    final HttpClientResponse response = await request.close().timeout(
      responseHeaderTimeout,
      onTimeout: () {
        // Nothing has been read yet, so the body is not the problem: give up on
        // this connection instead of holding the entry "busy" forever.
        try {
          request.abort();
        } catch (_) {
          // Already completed on the way out.
        }
        throw TimeoutException(
          'no response headers while downloading audio',
          responseHeaderTimeout,
        );
      },
    );
    if (_cancelled) return;
    // A range starting past the end means the cache file already holds everything the server has,
    // which is a finished download rather than a failure. It is also the only way to learn the size
    // of a fully cached track whose provider never announced one, so it is recorded here: for a file
    // the server will not serve a byte beyond, the file's length *is* the track's length.
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        position > 0) {
      final String? range = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      final RegExpMatch? match = range == null
          ? null
          : RegExp(r'^[Bb]ytes \*/(\d+)$').firstMatch(range.trim());
      if (match == null || int.tryParse(match.group(1)!) != position) {
        throw const HttpException(
          'cached audio length does not match range response',
        );
      }
      await response.drain<void>();
      await _sink?.close();
      _sink = null;
      _downloadedBytes = position;
      expectedBytes = position;
      _complete = true;
      _lastProgressAt = DateTime.now();
      _announceLength();
      return;
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException(
        'HTTP ${response.statusCode} while downloading audio',
      );
    }
    if (response.statusCode == HttpStatus.partialContent) {
      final String? range = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      final RegExpMatch? match = range == null
          ? null
          : RegExp(r'^[Bb]ytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(range.trim());
      final int? start = match == null ? null : int.tryParse(match.group(1)!);
      final int? end = match == null ? null : int.tryParse(match.group(2)!);
      if (start != position || end == null || end < position) {
        throw const HttpException(
          'audio range response starts at the wrong offset',
        );
      }
    }
    // A server that ignores the range restarts the body at zero, so the partial
    // file has to be truncated or the bytes would be prepended twice.
    final bool appending =
        position > 0 && response.statusCode == HttpStatus.partialContent;
    if (position > 0 && !appending) {
      await _sink?.close();
      _sink = await file.open(mode: FileMode.write);
      position = 0;
      _downloadedBytes = 0;
    }
    final int? total = _totalBytes(response, position);
    if (total != null) {
      expectedBytes = total;
      // Announce even when the wait for it already expired: `expectedLengthWithin` gives up after a
      // timeout, and the size that lands afterwards still has to reach the demuxer, which cannot
      // turn a seek's timestamp into a byte offset without it.
      _announceLength();
    }

    final body = StreamIterator<List<int>>(
      response.timeout(const Duration(seconds: 20)),
    );
    _body = body;
    while (await body.moveNext()) {
      if (_cancelled) return;
      final chunk = body.current;
      if (chunk.isEmpty) continue;
      final RandomAccessFile sink = _sink ??= await file.open(
        mode: FileMode.append,
      );
      // Body bytes without a response length: the server never announced a total,
      // so nothing is gained by waiting for one.
      _resolveLength();
      // Awaiting disk I/O applies backpressure and keeps large lossless sources
      // off the UI isolate without accumulating their bodies in memory.
      await sink.writeFrom(chunk);
      if (_cancelled) return;
      position += chunk.length;
      _downloadedBytes = position;
      _lastProgressAt = DateTime.now();
      _notifyAppended();
    }
    if (_cancelled) return;
    final int? expected = expectedBytes;
    if (expected != null && expected > 0 && position != expected) {
      throw const FileSystemException('audio download length does not match');
    }
    _complete = true;
    _lastProgressAt = DateTime.now();
  }

  /// Total size from `Content-Length`, or from `Content-Range` when resuming.
  int? _totalBytes(HttpClientResponse response, int position) {
    final String? range = response.headers.value(
      HttpHeaders.contentRangeHeader,
    );
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

/// One reader's ownership and notifications, independent of other readers.
class AudioStreamLease {
  AudioStreamLease._(this.entry);

  final AudioStreamEntry entry;
  bool _released = false;
  void Function()? _appended, _lengthKnown;
  void Function(bool)? _finished;

  void bindReader({
    required void Function() appended,
    required void Function(bool failed) finished,
    void Function()? lengthKnown,
  }) {
    if (_released) throw StateError('the audio cache lease is released');
    _appended = appended;
    _finished = finished;
    _lengthKnown = lengthKnown;
    appended();
    lengthKnown?.call();
    if (entry.complete || entry.cancelled || entry.failure != null) {
      finished(!entry.complete);
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    entry._leases.remove(this);
    _appended = null;
    _finished = null;
    _lengthKnown = null;
    entry.cancelIfUnleased();
  }
}
