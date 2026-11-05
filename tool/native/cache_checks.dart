// Behavioural checks for the download that feeds the engine's reader.
//
// Runs against a local HTTP server and a temp directory, so it is deterministic
// and needs neither Flutter nor the native library. Two entry points use it:
//   * `test/audio/audio_stream_cache_test.dart` (CI, `flutter test`)
//   * `tool/native_cache_check.dart` (plain `dart`)
//
// Each check returns the failures it found; an empty list means the cache
// behaved as the engine's reader contract requires: bytes are readable while the
// download runs, a restart resumes instead of corrupting, and a failed download
// is reported as a failure rather than a short track.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';

/// One `open()` → download → assert cycle.
Future<List<String>> verifyAudioStreamCache(Directory root) async {
  final List<String> failures = <String>[];

  void expect(String what, Object? actual, Object? expected) {
    if ('$actual' != '$expected') {
      failures.add('$what: $actual (expected $expected)');
    }
  }

  Future<AudioStreamCache> cacheAt(String name) async {
    final Directory directory = Directory('${root.path}/$name');
    await directory.create(recursive: true);
    return AudioStreamCache(() async => directory);
  }

  // 1. A whole download: the file grows while the entry reports progress, ends
  //    complete, and its bytes are exactly what the server sent.
  {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(64, (int index) => index),
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<void> served = Completer<void>();
    server.listen((HttpRequest request) async {
      request.response.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
      if (!served.isCompleted) served.complete();
    });
    final AudioStreamCache cache = await cacheAt('full');
    try {
      final AudioStreamEntry entry = await cache.open(
        'http://${server.address.host}:${server.port}/track.flac',
        expectedBytes: payload.length,
      );
      await served.future;
      await entry.done;
      expect('full download completes', entry.complete, true);
      expect('full download progress', entry.progress, 1.0);
      expect('full download byte count', entry.downloadedBytes, 64);
      expect(
        'full download bytes on disk',
        (await entry.file.readAsBytes()).length,
        64,
      );
    } finally {
      cache.close();
      await server.close(force: true);
    }
  }

  // 2. An interrupted download resumes from what is already on disk instead of
  //    restarting, so a track that was partly fetched is not fetched twice.
  {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(32, (int index) => 100 + index),
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<String?> rangeHeaders = <String?>[];
    final Completer<void> firstChunkSent = Completer<void>();
    final Completer<void> allowFirstChunkDone = Completer<void>();
    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      rangeHeaders.add(range);
      if (rangeHeaders.length == 1) {
        // First attempt: hand out a few bytes, then stall so the app has a
        // partial file to resume from.
        request.response.bufferOutput = false;
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = payload.length;
        request.response.add(payload.sublist(0, 8));
        await request.response.flush();
        if (!firstChunkSent.isCompleted) firstChunkSent.complete();
        await allowFirstChunkDone.future;
        return;
      }
      final int start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      request.response.statusCode = range == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      if (range != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
      }
      request.response.add(payload.sublist(start));
      await request.response.close();
    });
    final AudioStreamCache cache = await cacheAt('resume');
    try {
      final AudioStreamEntry first = await cache.open(
        'http://${server.address.host}:${server.port}/resume.flac',
        expectedBytes: payload.length,
      );
      await firstChunkSent.future;
      // Give the entry time to store the first chunk, then abandon it the way a
      // track change does.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      first.cancel();
      allowFirstChunkDone.complete();
      final int partialBytes = first.downloadedBytes;
      expect('partial download kept its bytes', partialBytes > 0, true);

      final AudioStreamEntry resumed = await cache.open(
        'http://${server.address.host}:${server.port}/resume.flac',
        expectedBytes: payload.length,
      );
      await resumed.done;
      expect('resume asked for a range', rangeHeaders.last != null, true);
      expect('resume completed', resumed.complete, true);
      final Uint8List bytes = await resumed.file.readAsBytes();
      expect('resumed file length', bytes.length, payload.length);
      expect('resumed file contents', _sameBytes(bytes, payload), true);
    } finally {
      cache.close();
      await server.close(force: true);
    }
  }

  // 3. A server that ignores the range restarts the body at zero; the cache must
  //    truncate instead of writing the same bytes twice.
  {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(16, (int index) => 200 + index),
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      // Always a full 200 body, even when a range was requested.
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });
    final AudioStreamCache cache = await cacheAt('norange');
    try {
      final AudioStreamEntry entry = await cache.open(
        'http://${server.address.host}:${server.port}/norange.flac',
        expectedBytes: payload.length,
      );
      await entry.done;
      final Uint8List bytes = await entry.file.readAsBytes();
      expect('no-range file length', bytes.length, payload.length);
      expect('no-range file contents', _sameBytes(bytes, payload), true);
    } finally {
      cache.close();
      await server.close(force: true);
    }
  }

  // 4. A failed download reports a failure and finishes, so the reader can turn
  //    it into a terminal error instead of pretending the track ended.
  {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    });
    final AudioStreamCache cache = await cacheAt('failure');
    final Completer<bool> finished = Completer<bool>();
    try {
      final AudioStreamEntry entry = await cache.open(
        'http://${server.address.host}:${server.port}/missing.flac',
      );
      entry.onFinished = (bool failed) {
        if (!finished.isCompleted) finished.complete(failed);
      };
      final bool reportedFailure = await finished.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
      expect('failed download reports failure', reportedFailure, true);
      expect('failed download is not complete', entry.complete, false);
      expect('failed download records the error', entry.failure != null, true);
    } finally {
      cache.close();
      await server.close(force: true);
    }
  }

  // 5. The cache keeps a bounded number of files so a long session cannot grow
  //    the disk without limit.
  {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      request.response.add(<int>[1, 2, 3, 4]);
      await request.response.close();
    });
    final Directory directory = Directory('${root.path}/evict');
    await directory.create(recursive: true);
    final AudioStreamCache cache = AudioStreamCache(
      () async => directory,
      maximumEntries: 1,
    );
    try {
      final String base = 'http://${server.address.host}:${server.port}';
      final AudioStreamEntry first = await cache.open('$base/one.flac');
      await first.done;
      final AudioStreamEntry second = await cache.open('$base/two.flac');
      await second.done;
      expect('evicted file was removed', await first.file.exists(), false);
      expect('newest file is kept', await second.file.exists(), true);
    } finally {
      cache.close();
      await server.close(force: true);
    }
  }

  // 6. A server that never announces a length: while the response is still
  //    open the fraction is unmeasurable, not zero. Reporting 0 % here is what
  //    made the buffer bar look empty for a downloaded chunked response.
  {
    final Completer<void> gate = Completer<void>();
    final int half = 32 * 1024;
    final List<int> payload = List<int>.generate(
      half * 2,
      (int index) => index & 0xff,
    );
    final Completer<void> bodyHeld = Completer<void>();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      // Writing without setting `contentLength` makes the server use chunked
      // transfer encoding: no length is announced, exactly like a CDN that
      // streams a rendition it has not sized up front.
      request.response.bufferOutput = false;
      request.response.add(payload.sublist(0, half));
      await request.response.flush();
      if (!bodyHeld.isCompleted) bodyHeld.complete();
      await gate.future;
      request.response.add(payload.sublist(half));
      await request.response.close();
    });
    final AudioStreamCache cache = await cacheAt('unknown-length');
    try {
      final AudioStreamEntry entry = await cache.open(
        'http://${server.address.host}:${server.port}/chunked.mp3',
      );
      await bodyHeld.future;
      await _waitFor(
        () => entry.downloadedBytes > 0,
        const Duration(seconds: 5),
      );
      expect(
        'length-less download bytes while open',
        entry.downloadedBytes,
        half,
      );
      expect(
        'length-less download is unmeasurable (no announced total)',
        entry.progress,
        null,
      );
      expect('length-less download knows no length', entry.lengthKnown, false);
      expect('length-less download is not complete', entry.complete, false);

      gate.complete();
      await entry.done;
      expect('length-less download completes', entry.complete, true);
      expect(
        'a finished download is whole',
        await entry.file.length(),
        payload.length,
      );
      expect(
        'a finished download reports complete (file fully readable)',
        entry.progress,
        1.0,
      );
    } finally {
      if (!gate.isCompleted) gate.complete();
      cache.close();
      await server.close(force: true);
    }
  }

  // 7. A download that stops delivering is reported as stalled, and a finished
  //    one never is. This is what lets the player recover a parked decoder
  //    instead of waiting out the reader's own 45 s deadline.
  //
  //    The body is deliberately larger than the client's read buffer: a small
  //    response is buffered whole by `HttpClient` and would never look like a
  //    partial read, which is a property of the test client, not of the cache.
  {
    final Completer<void> gate = Completer<void>();
    final List<int> payload = List<int>.generate(
      1024 * 1024,
      (int index) => index & 0xff,
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      request.response.contentLength = payload.length + 4;
      request.response.add(payload);
      await request.response.flush();
      await gate.future;
      request.response.add(<int>[9, 9, 9, 9]);
      await request.response.close();
    });
    final AudioStreamCache cache = await cacheAt('stall');
    try {
      final AudioStreamEntry entry = await cache.open(
        'http://${server.address.host}:${server.port}/slow.mp3',
      );
      // The response is deliberately held open, so wait for the bytes rather
      // than for a wall-clock guess.
      await _waitFor(
        () => entry.downloadedBytes > 0,
        const Duration(seconds: 10),
      );
      expect('a live download has bytes', entry.downloadedBytes > 0, true);
      expect(
        'a live download is not stalled',
        entry.stalledFor(const Duration(seconds: 5)),
        false,
      );
      await _waitFor(
        () => entry.stalledFor(const Duration(milliseconds: 30)),
        const Duration(seconds: 5),
      );
      expect(
        'a silent download is stalled',
        entry.stalledFor(const Duration(milliseconds: 30)),
        true,
      );
      gate.complete();
      await entry.done;
      expect('a finished download is not stalled', entry.complete, true);
      expect(
        'stall clears when the download finishes',
        entry.stalledFor(const Duration(milliseconds: 1)),
        false,
      );
    } finally {
      if (!gate.isCompleted) gate.complete();
      cache.close();
      await server.close(force: true);
    }
  }

  // 8. `open(force: true)` — the recovery path — starts a new entry over the
  //    same file and resumes from the bytes already on disk, so a dead download
  //    is not refetched from the beginning.
  {
    final List<int> payload = List<int>.generate(
      4096,
      (int index) => index & 0xff,
    );
    final List<String?> ranges = <String?>[];
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final int start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      request.response.statusCode = range == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      if (range != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
      }
      request.response.contentLength = payload.length - start;
      request.response.add(payload.sublist(start));
      await request.response.close();
    });
    final AudioStreamCache cache = await cacheAt('force-reopen');
    try {
      final String url =
          'http://${server.address.host}:${server.port}/again.mp3';
      final AudioStreamEntry first = await cache.open(
        url,
        expectedBytes: payload.length,
      );
      await first.done;
      expect(
        'first download completes',
        await first.file.length(),
        payload.length,
      );

      // Truncate the way a download that died mid-track leaves the file, then
      // take the recovery path.
      await first.file.writeAsBytes(payload.sublist(0, 1024), flush: true);
      final AudioStreamEntry second = await cache.open(
        url,
        expectedBytes: payload.length,
        force: true,
      );
      expect(
        'a forced reopen makes a new entry',
        identical(first, second),
        false,
      );
      await second.done;
      expect(
        'the restart resumes at the file size',
        ranges.last,
        'bytes=1024-',
      );
      final Uint8List resumed = await second.file.readAsBytes();
      expect(
        'the resumed file is the whole track',
        resumed.length,
        payload.length,
      );
      expect(
        'the resumed file is not a doubled prefix',
        _sameBytes(resumed, Uint8List.fromList(payload)),
        true,
      );
    } finally {
      cache.close();
      await server.close(force: true);
    }
  }

  // 9. A seek into a part of the track the linear download has not reached
  //    restarts the request at that offset, so the engine reads the region it
  //    asked for instead of waiting for a whole linear pass. The bytes between
  //    the prefix and the new window are a gap nobody wrote, and the ranges
  //    published to the reader must say so.
  {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(4 * 1024 * 1024, (int index) => index & 0xff),
    );
    final int prefixBytes = 64 * 1024;
    final Completer<void> releaseFirst = Completer<void>();
    final List<String?> ranges = <String?>[];
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final int start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      try {
        if (ranges.length == 1) {
          // The first pass stalls after a short prefix, the way a download that
          // is slower than the listener leaves the cache.
          request.response.bufferOutput = false;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${payload.length - 1}/${payload.length}',
          );
          request.response.add(payload.sublist(0, prefixBytes));
          await request.response.flush();
          await releaseFirst.future;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
        request.response.contentLength = payload.length - start;
        request.response.add(payload.sublist(start));
        await request.response.close();
      } catch (_) {
        // The client abandons the stalled body when it redirects; the server
        // side of that disconnect is not what this check is about.
      }
    });
    final Directory directory = Directory('${root.path}/ranged');
    await directory.create(recursive: true);
    final AudioStreamCache cache = AudioStreamCache(() async => directory);
    final String url = 'http://${server.address.host}:${server.port}/seek.flac';
    try {
      final AudioStreamEntry entry = await cache.open(
        url,
        expectedBytes: payload.length,
      );
      await _waitFor(
        () => entry.prefixEnd >= prefixBytes,
        const Duration(seconds: 5),
      );
      expect('the stalled prefix landed', entry.prefixEnd >= prefixBytes, true);
      expect('the announced length is known', entry.lengthKnown, true);

      // A seek well past the download, the way the engine asks for one.
      final int target = 3 * 1024 * 1024;
      const int windowStart = 3 * 1024 * 1024 - AudioStreamEntry.seekPrerollBytes;
      await entry.ensureRange(target, seek: true);
      await _waitFor(
        () => ranges.length > 1,
        const Duration(seconds: 5),
      );
      expect('the seek redirected the download', ranges.last, 'bytes=$windowStart-');
      expect('the window starts at the request', entry.windowStart, windowStart);
      expect(
        'the gap between the ranges is not readable',
        entry.readableEndAt(entry.prefixEnd),
        -1,
      );
      await _waitFor(
        () => entry.readableEndAt(target) > target,
        const Duration(seconds: 10),
      );
      expect(
        'the requested region became readable',
        entry.readableEndAt(target) > target,
        true,
      );
      final Uint8List onDisk = await entry.file.readAsBytes();
      final int fileOffset = entry.windowFileStart + (target - entry.windowStart);
      expect(
        'the redirected window holds the track bytes',
        _sameBytes(
          Uint8List.sublistView(onDisk, fileOffset, fileOffset + 4096),
          Uint8List.sublistView(payload, target, target + 4096),
        ),
        true,
      );

      // A byte inside the prefix needs no request at all.
      final int before = ranges.length;
      await entry.ensureRange(1024, seek: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect('a cached byte is served without a request', ranges.length, before);

      // The gap is remembered on disk, so a later launch cannot mistake the file
      // for a track that starts at byte zero.
      final File marker = File('${entry.file.path}.head');
      expect('the gap is recorded next to the file', await marker.exists(), true);
      expect(
        'the marker holds the prefix end',
        int.tryParse((await marker.readAsString()).trim()),
        entry.prefixEnd,
      );
      final AudioStreamEntry reopened = await cache.open(
        url,
        expectedBytes: payload.length,
        force: true,
      );
      await _waitFor(
        () => reopened.prefixEnd >= prefixBytes,
        const Duration(seconds: 5),
      );
      expect(
        'a reopened entry keeps the recorded prefix',
        reopened.prefixEnd >= prefixBytes,
        true,
      );
      expect(
        'a reopened entry restarts its window after the prefix',
        reopened.windowFileStart >= prefixBytes,
        true,
      );
      expect(
        'the prefix is readable after the reopen',
        reopened.readableEndAt(prefixBytes - 1),
        reopened.prefixEnd,
      );

      if (!releaseFirst.isCompleted) releaseFirst.complete();
      expect('the redirected bytes are past the announced end', target < payload.length, true);
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      cache.close();
      await server.close(force: true);
    }
  }

  // 10. A server that ignores the range restarts the body at zero, which the
  //     cache must survive without doubling the prefix or claiming a window it
  //     never wrote: out-of-range seeks are clamped from then on.
  {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(2 * 1024 * 1024, (int index) => (index * 7) & 0xff),
    );
    final int prefixBytes = 32 * 1024;
    final Completer<void> releaseFirst = Completer<void>();
    final List<String?> ranges = <String?>[];
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      try {
        if (ranges.length == 1) {
          // The first request is honoured as a range...
          request.response.bufferOutput = false;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${payload.length - 1}/${payload.length}',
          );
          request.response.add(payload.sublist(0, prefixBytes));
          await request.response.flush();
          await releaseFirst.future;
          await request.response.close();
          return;
        }
        // ...and every later one is answered with the whole body from zero.
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      } catch (_) {
        // See the ranged check: the abandoned body is expected.
      }
    });
    final Directory directory = Directory('${root.path}/no-redirect');
    await directory.create(recursive: true);
    final AudioStreamCache cache = AudioStreamCache(() async => directory);
    try {
      final AudioStreamEntry entry = await cache.open(
        'http://${server.address.host}:${server.port}/flat.mp3',
        expectedBytes: payload.length,
      );
      await _waitFor(
        () => entry.prefixEnd >= prefixBytes,
        const Duration(seconds: 5),
      );
      // Far enough past the prefix that the redirect starts inside the track
      // rather than at its beginning.
      await entry.ensureRange(3 * 1024 * 1024 ~/ 2, seek: true);
      await _waitFor(
        () => entry.complete,
        const Duration(seconds: 15),
      );
      expect('a range-less server is remembered', entry.rangeSupported, false);
      expect('the restarted body landed from zero', entry.windowStart, 0);
      expect('the file is the track once', entry.complete, true);
      final Uint8List onDisk = await entry.file.readAsBytes();
      expect('the file is not a doubled prefix', onDisk.length, payload.length);
      expect('the restarted file holds the track', _sameBytes(onDisk, payload), true);
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      cache.close();
      await server.close(force: true);
    }
  }

  return failures;
}

/// Waits until [condition] holds, or gives up after [timeout].
///
/// Used where the assertion is about *when* something happened rather than
/// about a wall-clock delay this check can rely on.
Future<void> _waitFor(bool Function() condition, Duration timeout) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (int index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
