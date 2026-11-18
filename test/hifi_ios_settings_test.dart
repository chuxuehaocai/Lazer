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
  @override
  String Function(Pointer<Void>) get lastError =>
      (_) => 'fixture refused the settings';

  @override
  int Function(Pointer<Void>, Pointer<LazerAudioStreamInfo>) get streamInfo =>
      (_, _) => lazerAudioErrorState;

  @override
  int Function(Pointer<Void>, Pointer<Int32>, Pointer<Uint8>, int)?
  get readLog => null;

  @override
  int Function(Pointer<Void>, Pointer<LazerAudioSnapshot>) get snapshot =>
      (_, _) => lazerAudioErrorState;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bridge implements LazerAudioBridgeApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Local playback must not create a streaming reader');
}

class _Worker implements LazerAudioWorker {
  final events = <String>[];
  final devices = <List<Object?>>[];
  final dsps = <List<Object?>>[];
  int dspResult = lazerAudioOk;
  int deviceResult = lazerAudioOk;

  @override
  Future<Object?> call(int op, List<Object?> params) async {
    events.add(LazerWorkerOp.describe(op));
    if (op == LazerWorkerOp.setDevice) {
      devices.add(List<Object?>.of(params));
      return deviceResult;
    }
    if (op == LazerWorkerOp.setDsp) {
      dsps.add(List<Object?>.of(params));
      return dspResult;
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
  final writes = <HifiSettings>[];
  const restored = HifiSettings(
    outputToken: 'desktop:dac',
    outputName: 'Desktop DAC',
    exclusiveMode: true,
    bitPerfect: true,
    dsdOutputMode: HifiDsdOutputMode.requireNative,
    buffer: HifiBufferSize.large,
    equalizer: HifiEqualizerState(enabled: true, preampDb: -3),
    crossfeed: HifiCrossfeedState(enabled: true, strength: 0.4),
  );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('lazer-hifi-ios-');
    worker = _Worker();
    engine = NativeAudioEngine.forTesting(
      api: _Api(),
      bridge: _Bridge(),
      worker: worker,
      cache: AudioStreamCache(() async => directory),
    );
    writes.clear();
    hifi = HifiController(
      restored,
      engine: engine,
      persist: (settings) async => writes.add(settings),
    );
  });

  tearDown(() async {
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

  test(
    'updated imported output choices stay consistent with applied DSP',
    () async {
      await hifi.update(
        restored.copyWith(
          equalizer: restored.equalizer.copyWith(preampDb: -8),
          dsdOutputMode: HifiDsdOutputMode.requireDoP,
        ),
      );
      expect(hifi.settings.bitPerfect, isFalse);
      expect(hifi.settings.outputToken, isNull);
      expect(hifi.settings.dsdOutputMode, HifiDsdOutputMode.convertToPcm);
      expect(worker.dsps.single[1], -8);
      expect(worker.dsps.single[4] as List, hasLength(10));
      // Disposal flushes the debounced preference write.
      hifi.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(writes.single.bitPerfect, isFalse);
      expect(writes.single.outputToken, isNull);
      expect(writes.single.dsdOutputMode, HifiDsdOutputMode.convertToPcm);
      hifi = HifiController(
        const HifiSettings(),
        engine: null,
        persist: (_) async {},
      );
    },
  );

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

  test(
    'restart restores DSP order while normalizing imported iOS output',
    () async {
      const order = <int>[2, 0, 1];
      final saved = restored.copyWith(dspStageOrder: order);
      SharedPreferences.setMockInitialValues({
        for (final entry in saved.toMap().entries)
          if (entry.value != null) entry.key: entry.value!,
      });
      hifi.dispose();
      hifi = HifiController(saved, engine: engine, persist: (_) async {});
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
        expect(worker.dsps.last[6], order);
      } finally {
        state.dispose();
      }
    },
  );

  testWidgets('iOS settings show PCM and bundled engine with applied errors', (
    tester,
  ) async {
    final state = AppState(hifi: hifi, hifiSettings: hifi.settings);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: SingleChildScrollView(child: HifiSettingsSection(state: state)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('import-audio-engine')), findsNothing);
    expect(find.byKey(const ValueKey('hifi-dsd-mode')), findsNothing);
    expect(find.text('PCM'), findsOneWidget);
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
  });

  test('desktop strict output choices remain explicit', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    hifi.dispose();
    hifi = HifiController(restored, engine: null, persist: (_) async {});
    expect(hifi.settings, same(restored));
    expect(hifi.normalizeSettings(restored), same(restored));
  });
}
