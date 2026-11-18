import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/hifi_controller_io.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api implements LazerAudioApi {
  bool streamIsOpen = false;
  int snapshotState = lazerAudioStateIdle;
  int terminalEvent = lazerAudioEventNone;

  @override
  String Function(Pointer<Void>) get lastError =>
      (_) => 'fixture refused the settings';

  @override
  int Function(Pointer<Void>, Pointer<LazerAudioStreamInfo>) get streamInfo =>
      (_, info) {
        if (!streamIsOpen) return lazerAudioErrorState;
        info.ref
          ..outputFormatInitialized = 1
          ..outputSampleRate = 48000
          ..outputBitsPerSample = 32
          ..outputChannels = 2
          ..outputContainerBitsPerSample = 32
          ..outputIsFloat = 1
          ..outputFormatSelection = lazerAudioFormatSelectionSharedMix
          ..outputFormatMatchesSource = 0
          ..outputExclusive = 0
          ..outputDspActive = 1
          ..bitPerfectActive = 0;
        return lazerAudioOk;
      };

  @override
  int Function(Pointer<Void>, Pointer<Int32>, Pointer<Uint8>, int)?
  get readLog => null;

  @override
  int Function(Pointer<Void>, Pointer<LazerAudioSnapshot>) get snapshot =>
      (_, snapshot) {
        snapshot.ref
          ..state = snapshotState
          ..terminalEvent = terminalEvent;
        return lazerAudioOk;
      };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bridge implements LazerAudioBridgeApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Local playback must not create a streaming reader');
}

class _Worker implements LazerAudioWorker {
  late _Api api;
  final events = <String>[];
  final devices = <List<Object?>>[];
  final dsps = <List<Object?>>[];
  int dspResult = lazerAudioOk;
  int deviceResult = lazerAudioOk;
  int stopResult = lazerAudioOk;
  int volumeResult = lazerAudioOk;
  int openResult = lazerAudioOk;

  @override
  Future<Object?> call(int op, List<Object?> params) async {
    events.add(LazerWorkerOp.describe(op));
    if (op == LazerWorkerOp.stop) {
      if (stopResult == lazerAudioOk) {
        api.streamIsOpen = false;
        api.snapshotState = lazerAudioStateStopped;
      }
      return stopResult;
    }
    if (op == LazerWorkerOp.setDevice) {
      devices.add(List<Object?>.of(params));
      return deviceResult;
    }
    if (op == LazerWorkerOp.setDsp) {
      dsps.add(List<Object?>.of(params));
      return dspResult;
    }
    if (op == LazerWorkerOp.setVolume) return volumeResult;
    if (op == LazerWorkerOp.openFile) {
      api.streamIsOpen = openResult == lazerAudioOk;
      api.snapshotState = api.streamIsOpen
          ? lazerAudioStateReady
          : lazerAudioStateFailed;
      api.terminalEvent = lazerAudioEventNone;
      return openResult;
    }
    return lazerAudioOk;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late NativeAudioEngine engine;
  late _Worker worker;
  late HifiController hifi;
  Object? cacheDirectoryFailure;
  final writes = <HifiSettings>[];
  const restored = HifiSettings(
    outputToken: 'desktop:dac',
    outputName: 'Desktop DAC',
    exclusiveMode: true,
    dsdOutputMode: HifiDsdOutputMode.requireNative,
    buffer: HifiBufferSize.large,
    equalizer: HifiEqualizerState(enabled: true, preampDb: -3),
    crossfeed: HifiCrossfeedState(enabled: true, strength: 0.4),
  );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('lazer-hifi-ios-');
    final api = _Api();
    cacheDirectoryFailure = null;
    worker = _Worker()..api = api;
    engine = NativeAudioEngine.forTesting(
      api: api,
      bridge: _Bridge(),
      worker: worker,
      cache: AudioStreamCache(() async {
        if (cacheDirectoryFailure case final error?) throw error;
        return directory;
      }),
    );
    writes.clear();
    hifi = HifiController(
      restored,
      engine: engine,
      persist: (settings) async => writes.add(settings),
    );
  });

  tearDown(() async {
    worker.stopResult = lazerAudioOk;
    hifi.dispose();
    engine.dispose();
    await engine.shutdownSettled;
    await directory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'desktop preferences become playable iOS PCM without discarding DSP',
    () async {
      expect(hifi.usesIosSystemRoute, isTrue);
      expect(hifi.supportsDevices, isFalse);
      expect(hifi.supportsExclusiveMode, isFalse);
      expect(hifi.supportsDoP, isFalse);
      expect(hifi.supportsBitPerfect, isFalse);
      expect(hifi.supportsNativeDsd, isFalse);
      expect(hifi.settings.outputToken, isNull);
      expect(hifi.settings.outputName, isNull);
      expect(hifi.settings.exclusiveMode, isFalse);
      expect(hifi.settings.bitPerfect, isFalse);
      expect(hifi.settings.dsdOutputMode, HifiDsdOutputMode.convertToPcm);
      expect(hifi.settings.equalizer, same(restored.equalizer));
      expect(hifi.settings.crossfeed, same(restored.crossfeed));
      expect(hifi.settings.eqActive, isTrue);
      expect(hifi.settings.crossfeedActive, isTrue);
      expect(hifi.settings.buffer, restored.buffer);
      expect(hifi.settings.forIosOutput(), same(hifi.settings));

      await hifi.apply();
      expect(hifi.lastApplyError, isNull);
      expect(worker.devices.single[1], 0); // Shared output.
      expect(worker.devices.single[4], restored.buffer.millis);
      expect(worker.devices.single[5], 0); // No bit-perfect promise.
      expect(worker.devices.single[6], lazerAudioDsdOutputConvertToPcm);
      expect(worker.devices.single[7], isNull);
      final dsp = worker.dsps.single;
      expect(dsp[1], -3);
      expect(dsp[2], 1); // Limiter remains enabled.
      expect(dsp[4] as List, hasLength(10));
      expect((dsp[5] as List)[0], 1); // Crossfeed remains enabled.

      var prepared = false;
      engine.prepareSession = () async => prepared = true;
      await engine.setUrl('${directory.path}/source.dsf');
      expect(prepared, isTrue);
      expect(engine.active, isTrue);
      expect(
        worker.events.where((event) => event == 'open_file'),
        hasLength(1),
      );
      expect(worker.devices.last[6], lazerAudioDsdOutputConvertToPcm);
      expect(worker.events, isNot(contains('play')));
    },
  );

  test('iOS route discovery has no missing desktop catalog error', () async {
    await hifi.refreshDevices();
    expect(hifi.devices, isEmpty);
    expect(hifi.deviceError, isNull);
    expect(hifi.endpointVolume, isNull);
  });

  test('saved DoP is normalized to PCM without bypassing DSP', () async {
    await hifi.update(
      restored.copyWith(
        equalizer: restored.equalizer.copyWith(preampDb: -8),
        dsdOutputMode: HifiDsdOutputMode.requireDoP,
      ),
    );
    expect(hifi.settings.bitPerfect, isFalse);
    expect(hifi.settings.exclusiveMode, isFalse);
    expect(hifi.settings.outputToken, isNull);
    expect(hifi.settings.dsdOutputMode, HifiDsdOutputMode.convertToPcm);
    expect(worker.dsps.single[1], -8);
    expect(worker.dsps.single[2], 1);
    expect(worker.dsps.single[4] as List, hasLength(10));
    expect((worker.dsps.single[5] as List)[0], 1);
    expect(
      worker.devices,
      isEmpty,
      reason: 'normalization keeps the old direct-output policy off the engine',
    );
    expect(hifi.settings.dspBypassedByDirectOutput, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(writes.single.bitPerfect, isFalse);
    expect(writes.single.outputToken, isNull);
    expect(writes.single.dsdOutputMode, HifiDsdOutputMode.convertToPcm);
  });

  test(
    'native DSP refusal reaches the controller and a retry clears it',
    () async {
      worker.dspResult = lazerAudioErrorUnsupported;
      await expectLater(engine.setEqualizer(preampDb: -3), throwsStateError);
      await hifi.apply();
      expect(hifi.lastApplyError, isA<StateError>());
      expect('${hifi.lastApplyError}', contains('fixture refused'));
      worker.dspResult = lazerAudioOk;
      await hifi.apply();
      expect(hifi.lastApplyError, isNull);
    },
  );

  test(
    'live DSP update reports a refusal instead of reporting success',
    () async {
      worker.dspResult = lazerAudioErrorUnsupported;
      await hifi.update(
        hifi.settings.copyWith(
          equalizer: hifi.settings.equalizer.copyWith(preampDb: -6),
        ),
      );
      expect(hifi.lastApplyError, isA<StateError>());
      worker.dspResult = lazerAudioOk;
      await hifi.update(
        hifi.settings.copyWith(
          equalizer: hifi.settings.equalizer.copyWith(preampDb: -9),
        ),
      );
      expect(hifi.lastApplyError, isNull);
    },
  );

  test('native output refusal reaches the controller', () async {
    worker.deviceResult = lazerAudioErrorUnsupported;
    await hifi.apply();
    expect(hifi.lastApplyError, isA<StateError>());
    expect(worker.dsps, isEmpty);
  });

  test(
    'an unrelated edit retries DSP after a partial settings failure',
    () async {
      worker.dspResult = lazerAudioErrorUnsupported;
      await hifi.apply();
      expect(hifi.lastApplyError, isNotNull);
      worker.dspResult = lazerAudioOk;
      await hifi.update(hifi.settings.copyWith(buffer: HifiBufferSize.small));
      expect(worker.dsps, hasLength(2));
      expect(worker.dsps.last[1], -3);
      expect(hifi.lastApplyError, isNull);
    },
  );

  test('the same settings can be retried after a transient refusal', () async {
    worker.dspResult = lazerAudioErrorUnsupported;
    await hifi.apply();
    worker.dspResult = lazerAudioOk;
    await hifi.update(hifi.settings);
    expect(worker.dsps, hasLength(2));
    expect(hifi.lastApplyError, isNull);
  });

  test(
    'source opening cannot silently retain a refused output policy',
    () async {
      worker.deviceResult = lazerAudioErrorUnsupported;
      await expectLater(
        engine.setUrl('${directory.path}/source.flac'),
        throwsStateError,
      );
      expect(engine.active, isFalse);
      expect(worker.events, isNot(contains('open_file')));
    },
  );

  test('source opening refuses a failed volume restoration', () async {
    worker.volumeResult = lazerAudioErrorUnsupported;
    await expectLater(
      engine.setUrl('${directory.path}/source.wav'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'reason',
          contains('Volume'),
        ),
      ),
    );
    expect(engine.active, isFalse);
    expect(worker.events, isNot(contains('open_file')));
  });

  test('non-finite engine volume never becomes unity gain', () async {
    await engine.setVolume(0.25);
    worker.events.clear();
    for (final invalid in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      await expectLater(engine.setVolume(invalid), throwsArgumentError);
      expect(engine.appliedVolume, 0.25);
    }
    expect(worker.events, isNot(contains('set_volume')));
  });

  test('source opening never retries policy after a refused stop', () async {
    await engine.setUrl('${directory.path}/first.wav');
    worker.deviceResult = lazerAudioErrorState;
    worker.stopResult = lazerAudioErrorDevice;
    worker.events.clear();
    await expectLater(
      engine.setUrl('${directory.path}/replacement.wav'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'reason',
          contains('stop'),
        ),
      ),
    );
    expect(worker.events.where((event) => event == 'set_device'), hasLength(1));
    expect(worker.events, isNot(contains('open_file')));
  });

  test('a rejected replacement retires the previous output snapshot', () async {
    hifi.attach();
    await engine.setUrl('${directory.path}/first.wav');
    await Future<void>.delayed(Duration.zero);
    expect(hifi.outputPath, isNotNull);
    worker.openResult = lazerAudioErrorUnsupported;
    await expectLater(
      engine.setUrl('${directory.path}/replacement.wav'),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(engine.active, isFalse);
    expect(engine.streamInfo, isNull);
    expect(hifi.outputPath, isNull);
  });

  test(
    'device loss retires the output path and active source immediately',
    () async {
      hifi.attach();
      await engine.setUrl('${directory.path}/shared.wav');
      await Future<void>.delayed(Duration.zero);
      expect(hifi.outputPath, isNotNull);
      worker.api
        ..snapshotState = lazerAudioStateFailed
        ..terminalEvent = lazerAudioEventDeviceLost;
      engine.deliverEventForTesting(lazerAudioEventDeviceLost);
      await Future<void>.delayed(Duration.zero);
      expect(engine.active, isFalse);
      expect(engine.streamInfo, isNull);
      expect(hifi.outputPath, isNull);
    },
  );

  test(
    'delayed terminal callbacks never retire a newly opened source',
    () async {
      hifi.attach();
      await engine.setUrl('${directory.path}/shared.wav');
      await Future<void>.delayed(Duration.zero);
      for (final state in [
        lazerAudioStatePreparing,
        lazerAudioStateReady,
        lazerAudioStatePlaying,
      ]) {
        worker.api.snapshotState = state;
        for (final event in [
          lazerAudioEventFailed,
          lazerAudioEventDeviceLost,
          lazerAudioEventEnded,
        ]) {
          engine.deliverEventForTesting(event);
          expect(engine.active, isTrue);
          expect(engine.streamInfo?.outputPath, isNotNull);
        }
      }
      // Even another terminal type must match the current published record.
      worker.api
        ..snapshotState = lazerAudioStateFailed
        ..terminalEvent = lazerAudioEventFailed;
      engine.deliverEventForTesting(lazerAudioEventDeviceLost);
      expect(engine.active, isTrue);
      engine.deliverEventForTesting(lazerAudioEventFailed);
      await Future<void>.delayed(Duration.zero);
      expect(engine.active, isFalse);
      expect(hifi.outputPath, isNull);
    },
  );

  for (final failure in ['session', 'cache']) {
    test(
      '$failure failure before native open cannot revive an old output path',
      () async {
        hifi.attach();
        await engine.setUrl('${directory.path}/first.wav');
        await Future<void>.delayed(Duration.zero);
        expect(hifi.outputPath, isNotNull);
        if (failure == 'session') {
          engine.prepareSession = () async =>
              throw StateError('session refused');
        } else {
          cacheDirectoryFailure = FileSystemException('cache unavailable');
        }
        final source = failure == 'cache'
            ? 'https://audio.test/replacement.wav'
            : '${directory.path}/replacement.wav';
        await expectLater(engine.setUrl(source), throwsA(anything));
        await Future<void>.delayed(Duration.zero);
        // The old native session can still answer, but it no longer describes
        // the source the listener requested. A synchronous read must not revive it.
        expect(worker.api.streamIsOpen, isTrue);
        expect(engine.readStreamInfo(), isNull);
        expect(engine.streamInfo, isNull);
        expect(hifi.outputPath, isNull);
      },
    );
  }

  for (final controllerHasSavedSettings in [false, true]) {
    test(
      'restart restores DSP order with existing settings: $controllerHasSavedSettings',
      () async {
        const order = <int>[2, 0, 1];
        final saved = restored.copyWith(dspStageOrder: order);
        SharedPreferences.setMockInitialValues({
          for (final entry in saved.toMap().entries)
            if (entry.value != null) entry.key: entry.value!,
        });
        hifi.dispose();
        // The controller can predate the preferences restoration. The state and
        // the native DSP still have to adopt the same restored snapshot.
        hifi = HifiController(
          controllerHasSavedSettings ? saved : const HifiSettings(),
          engine: engine,
          persist: (_) async {},
        );
        final state = AppState(
          hifi: hifi,
          queueStore: PlaybackQueueStore(
            read: () async => null,
            write: (_) async {},
          ),
          artworkSeedLoader: (_) async => null,
        );
        try {
          await state.bootstrap();
          expect(state.hifiSettings.dspStageOrder, order);
          expect(state.hifiSettings.bitPerfect, isFalse);
          expect(state.hifiSettings.outputToken, isNull);
          expect(
            state.hifiSettings.dsdOutputMode,
            HifiDsdOutputMode.convertToPcm,
          );
          expect(state.hifiSettings.eqActive, isTrue);
          expect(hifi.settings.equalizer.preampDb, -3);
          expect(hifi.settings.dspStageOrder, order);
          expect(worker.devices, hasLength(1));
          expect(worker.dsps, hasLength(1));
          expect(worker.dsps.last[6], order);
        } finally {
          state.dispose();
        }
      },
    );
  }

  testWidgets(
    'iOS settings show unsupported direct output and applied errors',
    (tester) async {
      final state = AppState(hifi: hifi, hifiSettings: hifi.settings);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: HifiSettingsSection(state: state),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('import-audio-engine')), findsNothing);
      expect(find.byKey(const ValueKey('hifi-dsd-mode')), findsNothing);
      expect(find.text('独占输出'), findsNothing);
      expect(find.text('Bit-perfect 输出'), findsNothing);
      expect(find.text('DSD 输出'), findsNothing);
      expect(find.text('独占 / 严格 PCM / DoP'), findsOneWidget);
      expect(find.text('iOS 不支持独占、严格 PCM 或 DoP，使用系统共享输出'), findsOneWidget);
      expect(find.text('严格输出'), findsOneWidget);
      expect(find.text('不支持'), findsWidgets);
      expect(find.textContaining('iOS 管理输出路由'), findsOneWidget);
      expect(find.textContaining('iOS 使用应用内置的原生引擎'), findsOneWidget);
      worker.dspResult = lazerAudioErrorUnsupported;
      await hifi.apply();
      await tester.pump();
      expect(find.textContaining('音频设置未应用：'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test('every saved iOS DSD and strict-output policy becomes PCM', () {
    for (final mode in HifiDsdOutputMode.values) {
      final settings = restored
          .copyWith(bitPerfect: true, dsdOutputMode: mode)
          .forIosOutput();
      expect(settings.exclusiveMode, isFalse);
      expect(settings.bitPerfect, isFalse);
      expect(settings.outputToken, isNull);
      expect(settings.outputName, isNull);
      expect(settings.dsdOutputMode, HifiDsdOutputMode.convertToPcm);
      expect(settings.toOutputRequest().dsdOutputMode.fallbackChain, [
        HifiDsdOutputMode.convertToPcm,
      ]);
    }
  });

  test(
    'iOS exclusive and bit-perfect requests cannot reach the engine',
    () async {
      final strict = restored.copyWith(
        exclusiveMode: true,
        bitPerfect: true,
        dsdOutputMode: HifiDsdOutputMode.convertToPcm,
      );
      await hifi.update(strict);
      expect(hifi.settings.bitPerfect, isFalse);
      expect(hifi.settings.exclusiveMode, isFalse);
      expect(hifi.settings.outputToken, isNull);
      expect(worker.devices, isEmpty);
      expect(worker.dsps, isEmpty);
      expect(hifi.settings.equalizer, same(restored.equalizer));
      expect(hifi.settings.crossfeed, same(restored.crossfeed));
    },
  );

  testWidgets(
    'iOS direct-output controls are absent and stale requests normalize',
    (tester) async {
      final state = AppState(hifi: hifi, hifiSettings: hifi.settings);
      await state.setVolume(0.25);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: HifiSettingsSection(state: state),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('独占输出'), findsNothing);
      expect(find.text('Bit-perfect 输出'), findsNothing);
      expect(find.text('DSD 输出'), findsNothing);
      expect(find.byKey(const ValueKey('hifi-dsd-mode')), findsNothing);
      await hifi.update(
        hifi.settings.copyWith(
          exclusiveMode: true,
          bitPerfect: true,
          dsdOutputMode: HifiDsdOutputMode.requireDoP,
        ),
      );
      await tester.pump();
      expect(state.hifiSettings.bitPerfect, isFalse);
      expect(state.hifiSettings.dsdOutputMode, HifiDsdOutputMode.convertToPcm);
      expect(state.hifiSettings.exclusiveMode, isFalse);
      expect(state.volume, 0.25);
      expect(find.textContaining('应用不会自动提高音量'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.pump(const Duration(milliseconds: 200));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test('desktop strict output choices remain explicit', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    hifi.dispose();
    hifi = HifiController(restored, engine: null, persist: (_) async {});
    expect(hifi.settings, same(restored));
    expect(hifi.normalizeSettings(restored), same(restored));
  });
}
