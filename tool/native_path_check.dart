// Checks that this build actually runs on the native HiFi engine.
//
// Two levels, so the cheap one can gate CI:
//
//   native-path-check --expect-native            # no audio device needed
//   native-path-check --play [--file tone.wav]   # live: needs an output device
//   native-path-check --play --bit-perfect       # the same, asking for the direct path
//   native-path-check --play --convolver [ir]    # put the FIR stage in the path, optionally with a WAV IR
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

import 'package:lazer_nextgen/audio/native/engine_metrics.dart';
import 'package:lazer_nextgen/audio/native/engine_selection.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';
import 'package:lazer_nextgen/audio/native/output_path_state.dart';

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
///
/// With `--bit-perfect` the session is opened exclusive + bit-perfect and the
/// three conditions behind that claim are printed, derived exactly the way the
/// UI derives them (`OutputPathState`). An endpoint that refuses the request is
/// reported as such, not treated as a failure: on most machines the default
/// device's mix format is not the file's.
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

  final bool bitPerfect = arguments.contains('--bit-perfect');
  final LazerDeviceSettings settings = LazerDeviceSettings(
    exclusive: bitPerfect,
    bitPerfect: bitPerfect,
  );

  final LazerAudioWorker worker = await LazerAudioWorker.spawn().timeout(
    const Duration(seconds: 15),
  );
  final Pointer<LazerAudioStreamInfo> info = calloc<LazerAudioStreamInfo>();
  final Pointer<LazerAudioSnapshot> snapshot = calloc<LazerAudioSnapshot>();
  int address = 0;
  try {
    final Object? created = await worker.call(LazerWorkerOp.create, <Object?>[
      ...settings.toDeviceMessage(),
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
    if (openStatus != lazerAudioOk) {
      // A bit-perfect request the endpoint cannot honour is an answer, not a bug:
      // the engine refuses instead of silently converting.
      stdout.writeln(
        formatAudioPathRecord('check.format', <String, Object?>{
          'requested_bit_perfect': bitPerfect ? 1 : 0,
          'open': 'refused',
          'error': api.lastError(engine),
        }),
      );
      _check(
        'the endpoint refused an unsupported format instead of converting it',
        bitPerfect,
        bitPerfect ? null : api.lastError(engine),
      );
      return;
    }
    _check('open known WAV', true);

    api.streamInfo(engine, info);
    final LazerStreamInfo stream = LazerStreamInfo.fromNative(info.ref);
    final OutputPathState path = stream.outputPath;
    api.snapshot(engine, snapshot);
    final LazerEngineMetrics metrics = LazerEngineMetrics.fromNative(
      snapshot.ref,
    );
    stdout.writeln(
      formatAudioPathRecord('check.format', <String, Object?>{
        'summary': stream.summary,
        'initialized': stream.outputFormatInitialized ? 1 : 0,
        'exclusive': path.exclusive ? 1 : 0,
        'dsp_active': path.dspActive ? 1 : 0,
        'format_matches_source': path.formatMatchesSource ? 1 : 0,
        'bit_perfect': path.bitPerfect ? 1 : 0,
        'engine_claims_bit_perfect': path.engineReportedBitPerfect ? 1 : 0,
        'unmet': path.failingConditions.isEmpty
            ? null
            : path.failingConditions.join(','),
        'ring_fill': metrics.ringFillFrames,
        'ring_capacity': metrics.ringCapacityFrames,
      }),
    );
    _check('the output session initialized', stream.outputFormatInitialized);
    _check(
      'the source decoded as the 44.1 kHz/16-bit WAV it is',
      stream.sourceSampleRate == 44100 && stream.sourceBitsPerSample == 16,
      '${stream.sourceSampleRate}/${stream.sourceBitsPerSample}',
    );
    // The engine's own flag and the three facts must tell the same story; a
    // disagreement is the bug this whole mechanism exists to expose.
    _check(
      'the engine flag agrees with the derived state',
      path.agreesWithEngine,
      path.agreesWithEngine ? null : 'engine=${path.engineReportedBitPerfect}',
    );
    if (bitPerfect) {
      _check(
        'an exclusive bit-perfect request produced a bit-perfect path',
        path.bitPerfect,
        path.failingConditions.join('；'),
      );
    }
    final String? convolverIr = _valueOf(arguments, '--convolver');
    if (convolverIr != null || arguments.contains('--convolver')) {
      await _applyConvolver(api, engine, info, convolverIr);
    }

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

/// Puts the FIR convolution stage in the signal path, so the one thing that needs real
/// hardware — "does the DSP change what leaves the engine, and does the path stop claiming
/// bit-perfect" — can be checked with one command.
///
/// The stage is not reachable from the app by design (no setting, no default IR, no UI). An
/// explicit `<ir>` takes a WAV file: PCM 8/16/24/32-bit or 32-bit float, channel count must
/// match the session (the engine refuses a mono IR on stereo rather than mixing channels).
/// Without a value a synthetic decaying echo is used, which is audible and obviously not
/// the source.
Future<void> _applyConvolver(
  LazerAudioApi api,
  Pointer<Void> engine,
  Pointer<LazerAudioStreamInfo> info,
  String? irPath,
) async {
  final List<List<double>> channels = irPath == null
      ? _syntheticImpulse()
      : _readWavImpulse(File(irPath));
  if (channels.isEmpty) {
    _check('the impulse response could be read', false, irPath ?? '(synthetic)');
    return;
  }
  final int frames = channels.first.length;
  final Pointer<Float> taps = calloc<Float>(frames * channels.length);
  final Pointer<LazerAudioDspConfig> config = calloc<LazerAudioDspConfig>();
  try {
    for (int channel = 0; channel < channels.length; channel++) {
      for (int tap = 0; tap < frames; tap++) {
        taps[channel * frames + tap] = channels[channel][tap];
      }
    }
    config.ref
      ..stageCount = 1
      ..impulseResponse = taps
      ..impulseResponseFrames = frames
      ..impulseResponseChannels = channels.length;
    config.ref.stageOrder[0] = lazerAudioDspStageConvolver;
    final int status = api.setDsp(engine, config);
    stdout.writeln(
      formatAudioPathRecord('check.convolver', <String, Object?>{
        'taps': frames,
        'channels': channels.length,
        'status': status,
        'error': status == lazerAudioOk ? null : api.lastError(engine),
      }),
    );
    _check('the convolver accepted the impulse response', status == lazerAudioOk);
    if (status != lazerAudioOk) return;
    /* Re-read the path: whatever it was before, a chain with the convolver in it is
     * processing, so `dsp_active` must be set and the derived bit-perfect verdict false. */
    api.streamInfo(engine, info);
    final OutputPathState after = LazerStreamInfo.fromNative(info.ref).outputPath;
    _check('the convolver is in the signal path', after.dspActive);
    _check('the path no longer claims bit-perfect', !after.bitPerfect,
        after.bitPerfectMeaning);
    _check(
      'the engine agrees with the derived verdict',
      after.agreesWithEngine,
      'engine=${after.engineReportedBitPerfect}',
    );
  } finally {
    calloc.free(taps);
    calloc.free(config);
  }
}

/// A stereo decaying echo: 8 taps at 0, 16 taps at 0.35, 40 taps at 0.15, rest silent.
List<List<double>> _syntheticImpulse() {
  const int frames = 64;
  List<double> channel() {
    final List<double> taps = List<double>.filled(frames, 0);
    taps[0] = 0.7;
    taps[16] = 0.35;
    taps[40] = 0.15;
    return taps;
  }

  return <List<double>>[channel(), channel()];
}

/// Reads a WAV file as float taps per channel. Returns an empty list when the file is not a
/// WAV this harness understands, so the caller reports that instead of guessing.
List<List<double>> _readWavImpulse(File file) {
  if (!file.existsSync()) return const <List<double>>[];
  final Uint8List bytes = file.readAsBytesSync();
  if (bytes.length < 44) return const <List<double>>[];
  final ByteData data = ByteData.sublistView(bytes);
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    return const <List<double>>[];
  }
  int offset = 12;
  int channels = 0;
  int bits = 0;
  int formatTag = 0;
  int dataOffset = 0;
  int dataLength = 0;
  while (offset + 8 <= bytes.length) {
    final String id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final int size = data.getUint32(offset + 4, Endian.little);
    final int body = offset + 8;
    if (id == 'fmt ' && body + 16 <= bytes.length) {
      formatTag = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = size;
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  if (channels <= 0 || dataOffset == 0 || dataLength <= 0) return const <List<double>>[];
  final bool floatFormat = formatTag == 3 && bits == 32;
  final int bytesPerSample = bits ~/ 8;
  if (!floatFormat && bytesPerSample != 1 && bytesPerSample != 2 &&
      bytesPerSample != 3 && bytesPerSample != 4) {
    return const <List<double>>[];
  }
  final int frames = dataLength ~/ (bytesPerSample * channels);
  final List<List<double>> taps = List<List<double>>.generate(
    channels,
    (_) => List<double>.filled(frames, 0),
  );
  for (int frame = 0; frame < frames; frame++) {
    for (int channel = 0; channel < channels; channel++) {
      final int at = dataOffset + (frame * channels + channel) * bytesPerSample;
      double value;
      if (floatFormat) {
        value = data.getFloat32(at, Endian.little);
      } else if (bytesPerSample == 1) {
        value = (bytes[at] - 128) / 128.0;
      } else if (bytesPerSample == 2) {
        value = data.getInt16(at, Endian.little) / 32768.0;
      } else if (bytesPerSample == 3) {
        final int raw = bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16);
        final int signed = raw & 0x800000 != 0 ? raw - 0x1000000 : raw;
        value = signed / 8388608.0;
      } else {
        value = data.getInt32(at, Endian.little) / 2147483648.0;
      }
      taps[channel][frame] = value;
    }
  }
  return taps;
}
