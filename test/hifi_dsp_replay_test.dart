import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/hifi_controller_io.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

class _ReplayEngine implements NativeAudioEngine {
  final snapshots = StreamController<LazerStreamInfo?>.broadcast(sync: true);
  Object? outputFailure;
  Object? dspFailure;
  int outputCalls = 0;
  int dspCalls = 0;

  @override
  bool hasPendingDspSettings = false;

  @override
  LazerStreamInfo? streamInfo;

  @override
  Stream<LazerStreamInfo?> get streamInfoStream => snapshots.stream;

  @override
  Future<void> setDeviceSettings(LazerDeviceSettings settings) async {
    outputCalls++;
    if (outputFailure case final error?) throw error;
  }

  @override
  Future<void> setEqualizer({
    double preampDb = 0,
    bool limiterEnabled = false,
    double limiterThresholdDb = -1,
    List<LazerEqBandSettings> bands = const <LazerEqBandSettings>[],
    LazerCrossfeedSettings crossfeed = const LazerCrossfeedSettings(),
    List<int> stageOrder = const <int>[],
  }) async {
    dspCalls++;
    hasPendingDspSettings = true;
    if (dspFailure case final error?) throw error;
    hasPendingDspSettings = false;
  }

  void publish(LazerStreamInfo? info) {
    streamInfo = info;
    snapshots.add(info);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LazerStreamInfo _openedStream({bool bitPerfect = false}) {
  final native = calloc<LazerAudioStreamInfo>();
  try {
    native.ref
      ..outputFormatInitialized = 1
      ..outputSampleRate = 48000
      ..outputBitsPerSample = 24
      ..outputChannels = 2
      ..outputFormatMatchesSource = 1
      ..outputExclusive = bitPerfect ? 1 : 0
      ..outputDspActive = bitPerfect ? 0 : 1
      ..bitPerfectActive = bitPerfect ? 1 : 0;
    return LazerStreamInfo.fromNative(native.ref);
  } finally {
    calloc.free(native);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ReplayEngine engine;
  late HifiController hifi;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    engine = _ReplayEngine();
    hifi = HifiController(
      const HifiSettings(),
      engine: engine,
      persist: (_) async {},
    )..attach();
  });

  tearDown(() async {
    hifi.dispose();
    await engine.snapshots.close();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final throughUpdate in [false, true]) {
    final operation = throughUpdate ? 'update' : 'apply';

    Future<void> applySettings() => throughUpdate
        ? hifi.update(
            hifi.settings.copyWith(
              equalizer: const HifiEqualizerState(enabled: true, preampDb: -3),
            ),
          )
        : hifi.apply();

    test(
      '$operation DSP error clears only after replay and a stream snapshot',
      () async {
        final refused = StateError(
          'DSP refused by the previous strict session',
        );
        engine.dspFailure = refused;
        await applySettings();
        expect(hifi.lastApplyError, same(refused));
        expect(engine.hasPendingDspSettings, isTrue);

        engine.publish(_openedStream());
        expect(hifi.lastApplyError, same(refused));
        engine.hasPendingDspSettings = false;
        engine.publish(null);
        expect(hifi.lastApplyError, same(refused));

        final outputCalls = engine.outputCalls;
        final dspCalls = engine.dspCalls;
        engine.publish(_openedStream());
        expect(hifi.lastApplyError, isNull);
        engine.publish(_openedStream());
        expect(engine.outputCalls, outputCalls);
        expect(engine.dspCalls, dspCalls);
      },
    );

    test('$operation output error survives an earlier DSP replay', () async {
      engine.dspFailure = StateError('pending DSP');
      await applySettings();
      final outputFailure = StateError('USB output no longer available');
      engine.outputFailure = outputFailure;
      await applySettings();
      expect(hifi.lastApplyError, same(outputFailure));

      engine.hasPendingDspSettings = false;
      engine.publish(_openedStream());
      expect(hifi.lastApplyError, same(outputFailure));
    });
  }

  test('leaving a strict stream defers DSP until the next open', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    const strict = HifiSettings(
      exclusiveMode: true,
      bitPerfect: true,
      equalizer: HifiEqualizerState(enabled: true, preampDb: -3),
    );
    await hifi.update(strict);
    expect(hifi.lastApplyError, isNull);

    engine.publish(_openedStream(bitPerfect: true));
    engine.dspFailure = StateError(
      'DSP is unavailable while the strict stream is active',
    );
    await hifi.update(strict.copyWith(exclusiveMode: false, bitPerfect: false));

    expect(hifi.lastApplyError, isNull);
    expect(hifi.dspDeferredUntilNextStream, isTrue);
    expect(engine.hasPendingDspSettings, isTrue);

    engine.hasPendingDspSettings = false;
    engine.publish(_openedStream());
    expect(hifi.dspDeferredUntilNextStream, isFalse);
  });
}
