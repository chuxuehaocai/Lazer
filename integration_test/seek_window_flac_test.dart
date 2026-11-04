// Diagnostic: forward seek into unread territory, on a format whose seek needs
// the demuxer to probe (FLAC's seek table is coarse, so libavformat binary-
// searches the byte range).
//
// A WAV seeks linearly, so it never probes; this is the case that matches the
// report where playback ends up back at the beginning.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a FLAC seek past the downloaded prefix resumes at the target',
    () async {
      final LazerAudioAvailability availability = LazerAudioLoader.load(
        reload: true,
      );
      if (availability.reason != null || !availability.supportsStreaming) {
        debugPrint('unavailable: ${availability.reason}');
        return;
      }

      final File fixture = File(
        '${Directory.current.path}${Platform.pathSeparator}build'
        '${Platform.pathSeparator}probe.flac',
      );
      if (!fixture.existsSync()) {
        debugPrint('missing fixture: ${fixture.path}');
        return;
      }
      final Uint8List body = fixture.readAsBytesSync();
      final int prefixEnd = body.length ~/ 4;
      debugPrint(
        'flac total=${body.length} bytes; serving the first '
        '${body.length ~/ 4} and feeding the rest slowly',
      );

      final held = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final String? range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          // A range request is the engine pulling the region the seek needs:
          // answer it at once, because that is the mechanism under test.
          final int start = int.parse(
            RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
          );
          final int end = (start + 4 * 1024 * 1024).clamp(0, body.length);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${body.length - 1}/${body.length}',
          );
          request.response.contentLength = end - start;
          request.response.add(body.sublist(start, end));
          await request.response.close();
          return;
        }
        request.response.contentLength = body.length;
        request.response.bufferOutput = false;
        request.response.add(body.sublist(0, prefixEnd));
        await request.response.flush();
        await held.future;
        var sent = prefixEnd;
        while (sent < body.length) {
          final int end = (sent + 64 * 1024).clamp(0, body.length);
          request.response.add(body.sublist(sent, end));
          await request.response.flush();
          sent = end;
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final root = await Directory.systemTemp.createTemp('lazer-flac-seek');
      addTearDown(() => root.delete(recursive: true));
      final cache = AudioStreamCache(() async => root);
      addTearDown(cache.close);

      final url = 'http://127.0.0.1:${server.port}/probe.flac';
      final entry = await cache.open(url, expectedBytes: body.length);
      for (var i = 0; i < 200 && entry.downloadedBytes < prefixEnd; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      debugPrint(
        'cache: bytes=${entry.downloadedBytes} '
        'complete=${entry.complete} progress=${entry.progress}',
      );
      expect(entry.complete, isFalse);

      final engine = await NativeAudioEngine.create(cache: cache);
      if (engine == null) {
        debugPrint('no engine: ${NativeAudioEngine.lastStartupFailure}');
        return;
      }
      addTearDown(engine.dispose);

      await engine.setQueue(<String>[url]);
      debugPrint(
        'opened: duration=${engine.duration} '
        'limited=${engine.seekIsLimitedByBuffer} '
        'buffered=${engine.bufferedPosition}',
      );

      await engine.play();
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        debugPrint('playing[$i] pos=${engine.position}');
      }

      const Duration target = Duration(seconds: 45);
      if (!held.isCompleted) held.complete();
      debugPrint('seeking to $target');
      final Stopwatch clock = Stopwatch()..start();
      await engine.seek(target);
      var elapsed = Duration.zero;
      // FLAC's seek table sends libavformat through a byte binary search, so this
      // is a looser bound than the WAV check: what it proves is that the region
      // arriving on demand unblocks the search, not that the search is cheap.
      var resumed = Duration.zero;
      while (elapsed < const Duration(seconds: 12)) {
        if (engine.position > target + const Duration(milliseconds: 500)) {
          resumed = engine.position;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        elapsed = clock.elapsed;
      }
      debugPrint(
        'resumed=$resumed after ${clock.elapsed.inMilliseconds} ms '
        'streamed=${engine.streamedBytes} failed=${engine.streamFailed}',
      );
      expect(
        resumed,
        greaterThan(target),
        reason:
            'a FLAC seek past the prefix must resume playing at the target '
            '(waited ${clock.elapsed.inMilliseconds} ms)',
      );

      await engine.stop();
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isWindows,
  );
}
