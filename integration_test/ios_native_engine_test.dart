// Runs on an iOS runtime (simulator or device) and answers the one question the
// build and link checks cannot: when the app is actually running on iOS, does
// the loader reach the linked engine and does the engine answer?
//
// `ci/verify-ios-audio.py` proves the ABI symbols are in the executable's
// dynamic export trie; this proves `DynamicLibrary.process()` resolves them,
// the reported ABI matches the Dart mirror, the reader bridge came along, and
// the engine answers a call. Whether it then produces correct sound on a real
// route is still a device question (docs/audio-engine-hardware-verification.md
// section 11).
//
//   flutter test integration_test/ios_native_engine_test.dart -d <simulator>
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lazer_nextgen/audio/engine_factory.dart';
import 'package:lazer_nextgen/audio/hifi_controller.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS selects the linked native engine', (
    WidgetTester tester,
  ) async {
    expect(
      Platform.isIOS,
      isTrue,
      reason: 'this check only means something on iOS',
    );
    expect(
      LazerAudioLoader.isSupportedHost,
      isTrue,
      reason: 'iOS must be offered the native path',
    );

    final LazerAudioAvailability availability = LazerAudioLoader.load(
      reload: true,
    );
    // The reason text is what the player shows on a downgrade, so a failure
    // here has to name the missing piece.
    expect(availability.reason, isNull);
    expect(availability.api, isNotNull);

    final LazerAudioApi api = availability.api!;
    expect(api.abiVersion(), lazerAudioAbiVersion);

    // Every ABI symbol resolved out of the process image, so the engine is
    // callable, not merely present in the binary.
    expect(api.buildInformation(), isNotEmpty);

    // The reader bridge is what plays network sources; it is linked into the
    // same image, so streaming must survive on iOS.
    expect(
      availability.supportsStreaming,
      isTrue,
      reason: 'the reader bridge must be reachable in-process too',
    );
  });

  testWidgets('iOS factory plays through the native engine and worker', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      final selection = await createAudioEngine();
      try {
        expect(selection.isNative, isTrue, reason: selection.description);
        expect(selection.path.notice, isNull);
        final engine = selection.native!;
        expect(engine.supportsStreaming, isTrue);
        final temporary = await Directory.systemTemp.createTemp('lazer-ios-');
        try {
          final file = File('${temporary.path}/silence.wav');
          await file.writeAsBytes(_pcmWav());
          await engine.setVolume(0);
          await engine.setUrl(file.uri.toString());
          expect(engine.active, isTrue);
          await engine.play();
          final clock = Stopwatch()..start();
          while (engine.position < const Duration(milliseconds: 100) &&
              clock.elapsed < const Duration(seconds: 5)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            engine.position,
            greaterThanOrEqualTo(const Duration(milliseconds: 100)),
            reason: 'RemoteIO must consume PCM from the native worker',
          );
          await engine.pause();
          await engine.seek(Duration.zero);
          await engine.stop();
          expect(engine.active, isFalse);
        } finally {
          await engine.stop();
          await temporary.delete(recursive: true);
        }
      } finally {
        selection.engine.dispose();
        await selection.native?.shutdownSettled;
      }
    });
  });

  testWidgets('iOS decodes high resolution PCM and DSD through RemoteIO', (
    tester,
  ) async {
    await tester.runAsync(
      () => _withNativeEngine((engine, directory) async {
        // No assumption that a Simulator, speaker or Bluetooth route grants the
        // source rate. This must decode high-rate input at the actual output rate.
        await engine.setVolume(0);
        for (final rate in [44100, 96000, 192000]) {
          final source = File('${directory.path}/pcm-$rate.wav');
          await source.writeAsBytes(_pcmWav(sampleRate: rate, bits: 24));
          await engine.setUrl(source.uri.toString());
          await _proveClock(engine);
          final info = engine.readStreamInfo()!;
          expect(info.sourceSampleRate, rate);
          expect(info.sourceBitsPerSample, 24);
          expect(info.outputSampleRate, greaterThan(0));
          expect(info.outputChannels, 2);
          expect(info.outputIsFloat, isTrue);
          expect(info.outputExclusive, isFalse);
          expect(info.bitPerfectActive, isFalse);
          await engine.stop();
        }

        final dsf = File('${directory.path}/dsd64.dsf');
        await dsf.writeAsBytes(_silentDsf());
        await engine.setUrl(dsf.uri.toString());
        await _proveClock(engine);
        final dsdInfo = engine.readStreamInfo()!;
        expect(dsdInfo.hasDsdSource, isTrue);
        expect(dsdInfo.sourceDsdRateMultiplier, 64);
        expect(dsdInfo.isDoPOutput, isFalse);
        expect(dsdInfo.isNativeDsdOutput, isFalse);
        expect(dsdInfo.outputSampleRate, greaterThan(0));
      }),
    );
  });

  testWidgets('iOS HiFi controller applies audible-path DSP', (tester) async {
    await tester.runAsync(
      () => _withNativeEngine((engine, directory) async {
        final hifi = HifiController(
          const HifiSettings(
            equalizer: HifiEqualizerState(limiterEnabled: false),
          ),
          engine: engine,
          persist: (_) async {},
        )..attach();
        try {
          final tone = File('${directory.path}/tone.wav');
          await tone.writeAsBytes(_pcmWav(tone: true));
          // Keep the test signal at approximately -66 dBFS on the real output.
          await engine.setVolume(0.005);
          await hifi.apply();
          expect(hifi.lastApplyError, isNull);
          await engine.setUrl(tone.uri.toString());
          await _proveClock(engine);
          final baseline = engine.readStreamInfo()!;
          expect(baseline.telemetryValid, isTrue);
          expect(baseline.peakMilliDbfs, greaterThan(-90000));
          await engine.stop();

          await hifi.update(
            hifi.settings.copyWith(
              equalizer: const HifiEqualizerState(
                preampDb: -12,
                limiterEnabled: false,
              ),
            ),
          );
          expect(hifi.lastApplyError, isNull);
          // Reopen to reset the engine's peak hold; otherwise the first pass
          // would mask attenuation even if the new DSP was correctly applied.
          await engine.setUrl(tone.uri.toString());
          await _proveClock(engine);
          final attenuated = engine.readStreamInfo()!;
          expect(attenuated.telemetryValid, isTrue);
          expect(
            attenuated.peakMilliDbfs - baseline.peakMilliDbfs,
            closeTo(-12000, 1000),
            reason:
                'the HifiController request must alter decoded PCM by 12 dB',
          );
          await engine.stop();

          await hifi.update(
            hifi.settings.copyWith(
              equalizer: const HifiEqualizerState(
                enabled: true,
                preampDb: -12,
              ).withBandGain(5, -6),
              crossfeed: const HifiCrossfeedState(
                enabled: true,
                algorithm: HifiCrossfeedAlgorithm.bs2b,
              ),
            ),
          );
          expect(hifi.lastApplyError, isNull);
          await engine.setUrl(tone.uri.toString());
          await _proveClock(engine);
          expect(engine.readStreamInfo()!.telemetryValid, isTrue);
        } finally {
          hifi.dispose();
        }
      }),
    );
  });

  testWidgets('iOS plays HTTP audio through the native growing reader', (
    tester,
  ) async {
    await tester.runAsync(
      () => _withNativeEngine((engine, directory) async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final bytes = _pcmWav();
        var requests = 0;
        final serving = <Future<void>>[];
        final listener = server.listen((request) {
          requests++;
          serving.add(() async {
            request.response.headers.contentType = ContentType('audio', 'wav');
            request.response.contentLength = bytes.length;
            try {
              for (var start = 0; start < bytes.length; start += 8192) {
                request.response.add(
                  bytes.sublist(start, math.min(start + 8192, bytes.length)),
                );
                await request.response.flush();
                await Future<void>.delayed(const Duration(milliseconds: 5));
              }
              await request.response.close();
            } on IOException {
              // Engine teardown may cancel a download after the playback proof.
            }
          }());
        });
        try {
          await engine.setVolume(0);
          await engine.setUrl('http://127.0.0.1:${server.port}/source.wav');
          await _proveClock(engine);
          expect(requests, greaterThan(0));
          expect(engine.readStreamInfo()!.sourceSampleRate, 44100);
          await engine.pause();
          await engine.seek(const Duration(milliseconds: 250));
          await _proveClock(engine, from: const Duration(milliseconds: 250));
        } finally {
          await engine.stop();
          await server.close(force: true);
          await listener.cancel();
          await Future.wait(serving);
        }
      }),
    );
  });

  testWidgets('iOS strict USB PCM refuses a non-USB route without fallback', (
    tester,
  ) async {
    await tester.runAsync(
      () => _proveNonUsbRefusal(
        const HifiSettings(
          bitPerfect: true,
          dsdOutputMode: HifiDsdOutputMode.convertToPcm,
          equalizer: HifiEqualizerState(limiterEnabled: false),
        ),
        'strict.wav',
        _pcmWav(bits: 24),
      ),
    );
  });

  testWidgets('iOS required DoP refuses a non-USB route without PCM fallback', (
    tester,
  ) async {
    await tester.runAsync(
      () => _proveNonUsbRefusal(
        const HifiSettings(
          dsdOutputMode: HifiDsdOutputMode.requireDoP,
          equalizer: HifiEqualizerState(limiterEnabled: false),
        ),
        'strict.dsf',
        _silentDsf(),
      ),
    );
  });
}

Future<void> _proveNonUsbRefusal(
  HifiSettings settings,
  String name,
  Uint8List bytes,
) async {
  await _withNativeEngine((engine, directory) async {
    final session = await AudioSession.instance;
    final outputs = await session.getDevices(
      includeInputs: false,
      includeOutputs: true,
    );
    expect(outputs, isNotEmpty, reason: 'the current iOS route must be known');
    // A real USB DAC is a separate hardware test. Never send an unverified DAC
    // a DoP carrier merely because somebody ran the Simulator integration suite
    // on an attached iPhone. CI has a non-USB Simulator route and runs both cases.
    // ignore: experimental_member_use
    if (outputs.any((output) => output.type == AudioDeviceType.usbAudio)) {
      markTestSkipped('non-USB rejection requires a speaker/headphone route');
      return;
    }

    final hifi = HifiController(settings, engine: engine, persist: (_) async {})
      ..attach();
    try {
      // This is engine gain only; never change the user's system volume. The
      // silent fixture and route refusal ensure the test emits no DoP payload.
      await engine.setVolume(1);
      await hifi.apply();
      expect(hifi.lastApplyError, isNull);
      expect(hifi.settings.bitPerfect, settings.bitPerfect);
      expect(hifi.settings.dsdOutputMode, settings.dsdOutputMode);
      final source = File('${directory.path}/$name');
      await source.writeAsBytes(bytes);
      await expectLater(
        engine.setUrl(source.uri.toString()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message.toString(),
            'native USB-only refusal',
            allOf(contains('($lazerAudioErrorUnsupported)'), contains('USB')),
          ),
        ),
      );
      expect(engine.active, isFalse, reason: 'strict policy must not play PCM');

      // Recovery is explicit: changing policy is the user's decision, not an
      // automatic fallback hidden behind a successful strict-mode open.
      await hifi.update(
        settings.copyWith(
          bitPerfect: false,
          dsdOutputMode: HifiDsdOutputMode.convertToPcm,
        ),
      );
      expect(hifi.lastApplyError, isNull);
      await engine.setVolume(0);
      await engine.setUrl(source.uri.toString());
      await _proveClock(engine);
      final info = engine.readStreamInfo()!;
      expect(info.bitPerfectActive, isFalse);
      expect(info.isDoPOutput, isFalse);
      expect(info.outputExclusive, isFalse);
    } finally {
      hifi.dispose();
    }
  });
}

Future<void> _withNativeEngine(
  Future<void> Function(NativeAudioEngine, Directory) run,
) async {
  expect(Platform.isIOS, isTrue);
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  final selection = await createAudioEngine();
  Directory? directory;
  try {
    expect(selection.isNative, isTrue, reason: selection.description);
    directory = await Directory.systemTemp.createTemp('lazer-ios-hifi-');
    await run(selection.native!, directory);
  } finally {
    selection.engine.dispose();
    // A second FFI owner cannot start until native threads and readers stop.
    await selection.native?.shutdownSettled;
    await directory?.delete(recursive: true);
  }
}

Future<void> _proveClock(
  NativeAudioEngine engine, {
  Duration from = Duration.zero,
}) async {
  await engine.play();
  final deadline = Stopwatch()..start();
  while (engine.position < from + const Duration(milliseconds: 300) &&
      deadline.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  expect(
    engine.position,
    greaterThanOrEqualTo(from + const Duration(milliseconds: 300)),
    reason: 'RemoteIO must consume native PCM: ${engine.lastError()}',
  );
  expect(engine.readStreamInfo()!.outputFormatInitialized, isTrue);
}

Uint8List _pcmWav({int sampleRate = 44100, int bits = 16, bool tone = false}) {
  const channels = 2;
  final frames = sampleRate * 2;
  final sampleBytes = bits ~/ 8;
  final bytes = Uint8List(44 + frames * channels * sampleBytes);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * sampleBytes, Endian.little);
  data.setUint16(32, channels * sampleBytes, Endian.little);
  data.setUint16(34, bits, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  if (tone) {
    for (var frame = 0; frame < frames; frame++) {
      final sample =
          (math.sin(frame * 2 * math.pi * 1000 / sampleRate) *
                  ((1 << (bits - 1)) - 1) *
                  0.1)
              .round();
      for (var channel = 0; channel < channels; channel++) {
        final offset = 44 + (frame * channels + channel) * sampleBytes;
        for (var byte = 0; byte < sampleBytes; byte++) {
          bytes[offset + byte] = (sample >> (8 * byte)) & 255;
        }
      }
    }
  }
  return bytes;
}

// Two seconds of DSD64 silence, in the same DSF framing as the native fixture
// generator. This proves the packaged DSD decoder, not USB DSD passthrough.
Uint8List _silentDsf() {
  const rate = 44100 * 64, frames = rate * 2, block = 4096;
  const blocks = (frames ~/ 8 + block - 1) ~/ block;
  final bytes = Uint8List(92 + blocks * block * 2);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'DSD ');
  data.setUint64(4, 28, Endian.little);
  data.setUint64(12, bytes.length, Endian.little);
  text(28, 'fmt ');
  data.setUint64(32, 52, Endian.little);
  data.setUint32(40, 1, Endian.little);
  data.setUint32(48, 2, Endian.little);
  data.setUint32(52, 2, Endian.little);
  data.setUint32(56, rate, Endian.little);
  data.setUint32(60, 8, Endian.little);
  data.setUint64(64, frames, Endian.little);
  data.setUint32(72, block, Endian.little);
  text(80, 'data');
  data.setUint64(84, bytes.length - 80, Endian.little);
  bytes.fillRange(92, bytes.length, 0x69);
  return bytes;
}
