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
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lazer_nextgen/audio/engine_factory.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

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
          await file.writeAsBytes(_silentWav());
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
      }
    });
  });
}

Uint8List _silentWav() {
  const sampleRate = 44100, channels = 2, bytesPerSample = 2;
  const dataSize = sampleRate * channels * bytesPerSample * 2;
  final bytes = Uint8List(44 + dataSize);
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
  data.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little);
  data.setUint16(32, channels * bytesPerSample, Endian.little);
  data.setUint16(34, bytesPerSample * 8, Endian.little);
  text(36, 'data');
  data.setUint32(40, dataSize, Endian.little);
  return bytes;
}
