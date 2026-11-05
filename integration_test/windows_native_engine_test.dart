// Answers the question the Dart-level suites cannot: on Windows, does the
// repository's own build actually load, accept a network source through the
// reader bridge, and report the format it negotiated?
//
//   dart run tool/build_native_audio.dart --ffmpeg-root <DSD FFmpeg>
//   flutter test integration_test/windows_native_engine_test.dart
//
// The engine is loaded from `build/native-audio`, the same directory the app
// uses when it runs from the repository root, so this exercises the shipped
// artifact rather than a stub. Opening a source needs no output device, so this
// runs on a headless host.
//
// It deliberately stops there. A "file still growing under the decoder" check
// cannot be made deterministic here: `dart:io`'s `HttpClient` buffers a bounded
// loopback body whole and delivers it when the response closes, so the test
// would be measuring the client's buffering rather than the engine's reading.
// The growing-file contract itself is covered by `tool/native_bridge_check.dart`
// (which drives the C callbacks the way the engine does) and by
// `tool/native_cache_checks.dart` (the downloader's own behaviour).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

/// A 2-channel 16-bit PCM WAV of [millis] of silence.
Uint8List _wav(int millis, {int sampleRate = 44100, int channels = 2}) {
  final int frames = sampleRate * millis ~/ 1000;
  final int dataBytes = frames * channels * 2;
  final BytesBuilder body = BytesBuilder();
  body.add(_ascii('RIFF'));
  body.add(_uint32(36 + dataBytes));
  body.add(_ascii('WAVEfmt '));
  body.add(_uint32(16));
  body.add(_uint16(1)); // PCM
  body.add(_uint16(channels));
  body.add(_uint32(sampleRate));
  body.add(_uint32(sampleRate * channels * 2)); // byte rate
  body.add(_uint16(channels * 2)); // block align
  body.add(_uint16(16)); // bits per sample
  body.add(_ascii('data'));
  body.add(_uint32(dataBytes));
  body.add(Uint8List(dataBytes));
  return body.takeBytes();
}

Uint8List _ascii(String text) =>
    Uint8List.fromList(text.codeUnits.map((int c) => c & 0xff).toList());

Uint8List _uint16(int value) =>
    Uint8List.fromList(<int>[value & 0xff, (value >> 8) & 0xff]);

Uint8List _uint32(int value) => Uint8List.fromList(<int>[
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the built Windows engine opens a network source', () async {
    final LazerAudioAvailability availability = LazerAudioLoader.load(
      reload: true,
    );
    expect(
      availability.reason,
      isNull,
      reason: 'build it first: dart run tool/build_native_audio.dart',
    );
    expect(availability.api, isNotNull);
    expect(
      availability.supportsStreaming,
      isTrue,
      reason: 'network playback needs the reader bridge',
    );

    final Uint8List body = _wav(2000);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final Directory root = await Directory.systemTemp.createTemp(
      'lazer-native-stream-test',
    );
    addTearDown(() => root.delete(recursive: true));
    final AudioStreamCache cache = AudioStreamCache(() async => root);
    addTearDown(cache.close);

    final String url = 'http://127.0.0.1:${server.port}/track.wav';
    final AudioStreamEntry entry = await cache.open(
      url,
      expectedBytes: body.length,
    );
    await entry.done;
    expect(entry.complete, isTrue);
    expect(entry.downloadedBytes, body.length);
    expect(await entry.file.length(), body.length);
    expect(entry.progress, 1.0, reason: 'an announced length makes it exact');

    final NativeAudioEngine? engine = await NativeAudioEngine.create(
      cache: cache,
    );
    expect(engine, isNotNull, reason: NativeAudioEngine.lastStartupFailure);
    addTearDown(() => engine!.dispose());

    await engine!.setQueue(<String>[url]);
    expect(engine.active, isTrue, reason: 'the engine accepted the source');

    final LazerStreamInfo? info = engine.streamInfo;
    expect(info, isNotNull, reason: 'opening a source publishes its format');
    expect(info!.sourceSampleRate, 44100);
    expect(info.sourceChannels, 2);
    expect(
      engine.duration,
      isNotNull,
      reason: 'the demuxer sized the stream from the announced length',
    );

    // The cache health the app's recovery path reads.
    expect(engine.streamedBytes, body.length);
    expect(engine.streamFailed, isFalse);
    expect(
      engine.seekIsLimitedByBuffer,
      isFalse,
      reason: 'a whole file can be seeked anywhere in it',
    );

    await engine.stop();
    expect(engine.active, isFalse);
  }, skip: !Platform.isWindows);

  // The rail-publishing half of this is covered by `test/buffered_seek_test.dart`.
  // What only a real engine can answer is whether the *demuxer* lands where it
  // was asked to: the Dart layer publishes the target while a seek is being
  // applied, and if the engine then reported somewhere else the rail would snap
  // — the "拖了之后回到开头" report.
  test('the built Windows engine seeks where it was asked', () async {
    final LazerAudioAvailability availability = LazerAudioLoader.load(
      reload: true,
    );
    expect(availability.reason, isNull);
    if (!availability.supportsStreaming) return;

    // Sixty seconds: a seek has somewhere to go, and decoding stays cheap.
    final Uint8List body = _wav(60000);
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final Directory root = await Directory.systemTemp.createTemp(
      'lazer-native-seek-test',
    );
    addTearDown(() => root.delete(recursive: true));
    final AudioStreamCache cache = AudioStreamCache(() async => root);
    addTearDown(cache.close);

    final String url = 'http://127.0.0.1:${server.port}/seek.wav';
    final AudioStreamEntry entry = await cache.open(
      url,
      expectedBytes: body.length,
    );
    await entry.done;

    final NativeAudioEngine? created = await NativeAudioEngine.create(
      cache: cache,
    );
    expect(created, isNotNull, reason: NativeAudioEngine.lastStartupFailure);
    final NativeAudioEngine engine = created!;
    addTearDown(engine.dispose);

    await engine.setQueue(<String>[url]);
    expect(engine.duration, const Duration(seconds: 60));

    const Duration target = Duration(seconds: 50);
    await engine.seek(target);
    // The engine publishes the requested target while the demuxer applies it,
    // so this is already true immediately after the call.
    expect(
      engine.position,
      target,
      reason: 'a requested seek is published, not the pre-seek position',
    );

    // And the demuxer really moved there: give it a moment to land, then check
    // that the clock is at the target rather than back at the start.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final Duration landed = engine.position;
    expect(
      landed,
      greaterThan(const Duration(seconds: 45)),
      reason: 'the engine must not land back near the beginning',
    );
    expect(landed, lessThan(const Duration(seconds: 55)));
    expect(engine.streamFailed, isFalse);

    await engine.stop();
  }, skip: !Platform.isWindows);
}
