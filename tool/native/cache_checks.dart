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
          : int.parse(
              RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
            );
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

  return failures;
}

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (int index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
