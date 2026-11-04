// Acceptance for "seek anywhere" on a source that is still arriving.
//
// A seek past what has been downloaded is the case this exists for:
// libavformat's seek is a byte-region binary search, so without help it probes
// regions that have not landed and blocks the demuxer on them — tens of seconds
// of frozen playhead and silence after the listener drags forward.
//
// The server holds the file back on purpose, so the seek really does land in
// unread territory; the engine is then expected to pull the region the decoder
// is waiting on and start playing there in about a second.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

import '../test/support/wav_fixture.dart';

/// A body of [seconds] of 16-bit stereo PCM, whose byte rate is fixed, so
/// truncating it at a byte offset means "the download has reached this second".
Future<({Uint8List body, int bytesPerSecond})> _pcm(int seconds) async {
  const int bytesPerSecond = 44100 * 2 * 2;
  return (body: wavFixture(seconds * 1000), bytesPerSecond: bytesPerSecond);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a seek past the downloaded prefix starts playing there, not seconds later',
    () async {
      final LazerAudioAvailability availability = LazerAudioLoader.load(
        reload: true,
      );
      expect(availability.reason, isNull);
      if (!availability.supportsStreaming) return;

      const int seconds = 60;
      final ({Uint8List body, int bytesPerSecond}) fixture = await _pcm(seconds);
      const int servedSeconds = 12;
      final int prefixEnd = servedSeconds * fixture.bytesPerSecond;

      // The remainder is fed slowly, so the seek target is genuinely unread and
      // would take ~20 s to arrive on its own.
      final Completer<void> feedRest = Completer<void>();
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest request) async {
        request.response.contentLength = fixture.body.length;
        request.response.bufferOutput = false;
        final String? range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          // The engine's own range request: answer it immediately, because that
          // is the mechanism under test.
          final int start = int.parse(
            RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
          );
          final int end = (start + 4 * 1024 * 1024).clamp(0, fixture.body.length);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${fixture.body.length - 1}/${fixture.body.length}',
          );
          request.response.contentLength = end - start;
          request.response.add(fixture.body.sublist(start, end));
          await request.response.close();
          return;
        }
        request.response.add(fixture.body.sublist(0, prefixEnd));
        await request.response.flush();
        await feedRest.future;
        var sent = prefixEnd;
        while (sent < fixture.body.length) {
          final int end = (sent + 64 * 1024).clamp(0, fixture.body.length);
          request.response.add(fixture.body.sublist(sent, end));
          await request.response.flush();
          sent = end;
          await Future<void>.delayed(const Duration(milliseconds: 160));
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      addTearDown(() {
        if (!feedRest.isCompleted) feedRest.complete();
      });

      final Directory root = await Directory.systemTemp.createTemp(
        'lazer-seek-window',
      );
      addTearDown(() => root.delete(recursive: true));
      final AudioStreamCache cache = AudioStreamCache(() async => root);
      addTearDown(cache.close);

      final String url = 'http://127.0.0.1:${server.port}/window.wav';
      final AudioStreamEntry entry = await cache.open(
        url,
        expectedBytes: fixture.body.length,
      );
      for (var i = 0; i < 200 && entry.downloadedBytes < prefixEnd; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(entry.complete, isFalse, reason: 'the file must still be short');

      final NativeAudioEngine? created = await NativeAudioEngine.create(
        cache: cache,
      );
      expect(created, isNotNull, reason: NativeAudioEngine.lastStartupFailure);
      final NativeAudioEngine engine = created!;
      addTearDown(engine.dispose);

      await engine.setQueue(<String>[url]);
      expect(engine.duration, const Duration(seconds: 60));
      await engine.play();
      for (var i = 0; i < 8 && engine.position < const Duration(seconds: 1); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final Duration before = engine.position;
      expect(before, greaterThan(Duration.zero), reason: 'playback started');

      // The seek under test: well past what has landed.
      const Duration target = Duration(seconds: 45);
      final Stopwatch clock = Stopwatch()..start();
      await engine.seek(target);

      // "Playing there" means the clock moves past the target within a couple of
      // seconds. Without the chase it sits at the target for ~30 s.
      var resumed = Duration.zero;
      while (clock.elapsed < const Duration(seconds: 8)) {
        if (engine.position > target + const Duration(milliseconds: 500)) {
          resumed = engine.position;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        resumed,
        greaterThan(target),
        reason:
            'the seek must resume playing at the target instead of parking '
            'the decoder on bytes that have not landed '
            '(waited ${clock.elapsed.inMilliseconds} ms)',
      );
      expect(
        clock.elapsed,
        lessThan(const Duration(seconds: 8)),
        reason: 'and it must not take the sequential download to get there',
      );
      expect(engine.streamFailed, isFalse);

      await engine.stop();
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isWindows,
  );
}
