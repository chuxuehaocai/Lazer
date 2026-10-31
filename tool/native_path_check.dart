// Checks that this build actually runs on the native HiFi engine.
//
// Two levels, so the cheap one can gate CI:
//
//   native-path-check --expect-native            # no audio device needed
//   native-path-check --play [--file tone.wav]   # live: needs an output device
//
// Compile it into a packaged bundle and run it from an unrelated working
// directory, so library resolution is exercised exactly as the app exercises it
// (`LazerAudioLoader` prefers the executable's directory for an installed build).
//
//   dart compile exe tool/native_path_check.dart -o <bundle>/native-path-check.exe
//   cd %TEMP% && <bundle>/native-path-check.exe --expect-native
//
// The launch decision itself is `planAudioEnginePath`, the same function
// `engine_factory.dart` uses, so this asserts the app's choice rather than a
// re-implementation of it.
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:lazer_nextgen/audio/native/engine_selection.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';

int _failures = 0;

void _check(String what, bool ok, [String? detail]) {
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $what${detail == null ? '' : ' — $detail'}');
  if (!ok) _failures++;
}

Future<void> main(List<String> arguments) async {
  final bool expectNative = arguments.contains('--expect-native');
  final bool expectFallback = arguments.contains('--expect-fallback');
  final bool play = arguments.contains('--play');
  final bool systemEngine = arguments.contains('--system-engine');

  final LazerAudioAvailability availability = LazerAudioLoader.load(
    reload: true,
  );
  final AudioEnginePathDecision decision = planAudioEnginePath(
    preferNative: !systemEngine,
    hostSupported: LazerAudioLoader.isSupportedHost,
    libraryUnavailableReason: availability.reason,
  );

  stdout.writeln(
    formatAudioPathRecord('check', <String, Object?>{
      'cwd': Directory.current.path,
      'host_supported': LazerAudioLoader.isSupportedHost ? 1 : 0,
      'library': availability.isAvailable ? 'loaded' : 'unavailable',
      'bridge': availability.supportsStreaming ? 'loaded' : 'unavailable',
      'decision': decision.path.name,
      'fallback': decision.fallback?.name,
      'detail': decision.detail,
    }),
  );

  if (expectNative) {
    _check(
      'launch path is the native engine',
      decision.isNative,
      decision.isNative ? null : '${decision.fallback?.name}: ${decision.detail}',
    );
    // Streaming needs the bridge; a bundle that ships the engine without it
    // would still be "native" but unable to play a network source.
    _check('reader bridge is loadable', availability.supportsStreaming);
  }
  if (expectFallback) {
    _check('launch path is the system engine', !decision.isNative);
    _check('the fallback carries a notice', decision.notice != null);
  }

  if (play && decision.isNative) {
    await _playKnownWav(arguments, availability.api!);
  }

  if (_failures > 0) {
    stderr.writeln('$_failures check(s) failed');
    exit(1);
  }
  stdout.writeln('all checks passed');
}

/// Plays a known WAV through the engine and reads back what it negotiated.
///
/// This is the "the engine really is the one producing sound" check: it opens a
/// file the tool itself wrote (deterministic bytes, no fixture in the repo),
/// starts playback, and requires the engine's own clock to advance while its
/// stream info reports an initialized output session.
Future<void> _playKnownWav(
  List<String> arguments,
  LazerAudioApi api,
) async {
  final String? explicit = _valueOf(arguments, '--file');
  final File fixture = explicit == null
      ? _writeFixture()
      : File(explicit);
  _check('fixture exists', fixture.existsSync(), fixture.path);
  if (!fixture.existsSync()) return;

  final LazerAudioWorker worker = await LazerAudioWorker.spawn().timeout(
    const Duration(seconds: 15),
  );
  final Pointer<LazerAudioStreamInfo> info = calloc<LazerAudioStreamInfo>();
  final Pointer<LazerAudioSnapshot> snapshot = calloc<LazerAudioSnapshot>();
  int address = 0;
  try {
    final Object? created = await worker.call(LazerWorkerOp.create, <Object?>[
      ...const LazerDeviceSettings().toDeviceMessage(),
      0,
      0,
    ]);
    _check('engine session created', created is int && created != 0);
    if (created is! int || created == 0) return;
    address = created;
    final Pointer<Void> engine = Pointer<Void>.fromAddress(address);

    final int openStatus =
        await worker.call(LazerWorkerOp.openFile, <Object?>[
              address,
              fixture.path,
              ...const LazerOpenSettings().toMessage(),
            ])
            as int;
    _check('open known WAV', openStatus == lazerAudioOk, openStatus == lazerAudioOk ? null : api.lastError(engine));
    if (openStatus != lazerAudioOk) return;

    api.streamInfo(engine, info);
    final LazerStreamInfo stream = LazerStreamInfo.fromNative(info.ref);
    stdout.writeln(
      formatAudioPathRecord('check.format', <String, Object?>{
        'summary': stream.summary,
        'initialized': stream.outputFormatInitialized ? 1 : 0,
        'exclusive': stream.outputExclusive ? 1 : 0,
        'bit_perfect': stream.bitPerfectActive ? 1 : 0,
      }),
    );
    _check('the output session initialized', stream.outputFormatInitialized);
    _check('the source decoded as the 44.1 kHz/16-bit WAV it is',
        stream.sourceSampleRate == 44100 && stream.sourceBitsPerSample == 16,
        '${stream.sourceSampleRate}/${stream.sourceBitsPerSample}');

    _check('play accepted', api.play(engine) == lazerAudioOk);
    final int? advanced = await _waitForClock(api, engine, snapshot, 1500);
    _check(
      'the engine clock advanced',
      advanced != null,
      advanced == null ? 'position never moved past 150 ms' : '${advanced}ms',
    );
    api.pause(engine);
  } finally {
    if (address != 0) {
      await worker.call(LazerWorkerOp.stop, <Object?>[address]);
      await worker.call(LazerWorkerOp.destroy, <Object?>[address]);
    }
    calloc.free(info);
    calloc.free(snapshot);
    await worker.close();
  }
}

/// Polls the engine's own snapshot; null when the clock never advances.
Future<int?> _waitForClock(
  LazerAudioApi api,
  Pointer<Void> engine,
  Pointer<LazerAudioSnapshot> snapshot,
  int thresholdMillis,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (api.snapshot(engine, snapshot) == lazerAudioOk) {
      final int position = snapshot.ref.positionMillis;
      if (position > thresholdMillis) return position;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return null;
}

/// A deterministic 44.1 kHz / 16-bit stereo WAV, so the check needs no fixture
/// checked into the repository.
File _writeFixture() {
  const int sampleRate = 44100;
  const int frames = sampleRate * 2; // two seconds
  const int channels = 2;
  const int bytesPerSample = 2;
  final ByteData samples = ByteData(frames * channels * bytesPerSample);
  for (int frame = 0; frame < frames; frame++) {
    // A 440 Hz tone at a quarter scale: loud enough to be audible if a human
    // runs this, quiet enough that nothing clips.
    final double value =
        math.sin(2 * math.pi * 440 * frame / sampleRate) * 0.25;
    final int pcm = (value * 32767).round();
    for (int channel = 0; channel < channels; channel++) {
      samples.setInt16(
        (frame * channels + channel) * bytesPerSample,
        pcm,
        Endian.little,
      );
    }
  }
  final Uint8List data = samples.buffer.asUint8List();
  final ByteData header = ByteData(44);
  void ascii(int offset, String text) {
    for (int index = 0; index < text.length; index++) {
      header.setUint8(offset + index, text.codeUnitAt(index));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + data.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little);
  header.setUint16(32, channels * bytesPerSample, Endian.little);
  header.setUint16(34, bytesPerSample * 8, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, data.length, Endian.little);

  final Directory directory = Directory.systemTemp.createTempSync(
    'lazer-native-path',
  );
  final File file = File('${directory.path}/tone441.wav');
  file.writeAsBytesSync(<int>[
    ...header.buffer.asUint8List(),
    ...data,
  ]);
  return file;
}

String? _valueOf(List<String> arguments, String flag) {
  final int index = arguments.indexOf(flag);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}
