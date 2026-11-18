import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/diagnostics/app_log.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

const Track _track = Track(
  id: 'resume-fixture',
  title: 'Resume fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 4),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  int resolveCalls = 0;
  bool failResolve = false;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async {
    resolveCalls++;
    if (failResolve) return null;
    return 'fixture://resume';
  }

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

class _Engine implements AudioEngine {
  Object? openFailure;
  Object? playFailure;
  int openCalls = 0;
  final StreamController<void> completions = StreamController<void>.broadcast();
  final List<Duration> seekRequests = <Duration>[];
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => _track.duration;
  @override
  Stream<void> get completed => completions.stream;
  @override
  Future<void> setUrl(String url) async {
    openCalls++;
    if (openFailure != null) throw openFailure!;
    active = true;
  }

  @override
  Future<void> play() async {
    if (playFailure != null) throw playFailure!;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async {
    seekRequests.add(value);
    position = value;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async => active = false;
  @override
  void dispose() {}
}

class _QueueEngine extends _Engine implements QueueAudioEngine {
  int queueCalls = 0;

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    queueCalls++;
    if (openFailure case final error?) throw error;
    active = true;
    return queueCalls;
  }

  @override
  Stream<int> get indexStream => const Stream<int>.empty();
  @override
  Future<bool> appendToQueue(int queueId, String url) async => false;
  @override
  Future<bool> clearQueued(int queueId) async => true;
  @override
  Future<bool> playQueuedNext() async => false;
}

class _DeviceEngine extends _Engine implements FailureReportingAudioEngine {
  final reports = StreamController<AudioFailure>.broadcast();
  @override
  Stream<AudioFailure> get failures => reports.stream;
  @override
  AudioFailure? get pendingFailure => null;

  void loseOutput() {
    active = false;
    reports.add(const AudioFailure('USB output lost', AudioFailureKind.device));
  }
}

Future<void> _until(bool Function() condition) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never became true');
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState stateWith(_Engine engine) {
    final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    return state;
  }

  test('play after an interruption resumes where the listener was', () async {
    final _Engine engine = _Engine();
    final AppState state = stateWith(engine);
    state.playQueue(<Track>[_track]);
    await _until(() => engine.active);
    engine.position = const Duration(seconds: 90);
    state.seek(0.5);
    await _until(
      () => engine.seekRequests.contains(const Duration(seconds: 120)),
    );
    expect(state.position, const Duration(seconds: 120));

    await state.suspendForInterruption();
    expect(state.playing, isFalse);
    expect(engine.active, isFalse);

    engine.seekRequests.clear();
    state.play();
    await _until(() => engine.active);
    await _until(() => engine.seekRequests.isNotEmpty);
    expect(
      engine.seekRequests.first,
      const Duration(seconds: 120),
      reason: 'the reopened source must seek back to the interrupted playhead',
    );
    expect(state.position, const Duration(seconds: 120));
  });

  test('play after a track ended starts the same song from zero', () async {
    final _Engine engine = _Engine();
    final AppState state = stateWith(engine);
    state.playQueue(<Track>[_track]);
    await _until(() => engine.active);
    engine.position = _track.duration;
    engine.completions.add(null);
    await _until(() => !state.playing);
    expect(state.position, _track.duration);

    engine.seekRequests.clear();
    state.play();
    await _until(() => engine.active);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      engine.seekRequests,
      isEmpty,
      reason: 'the end-of-track position is not a playhead to resume at',
    );
  });

  for (final String phase in <String>['open', 'play']) {
    test(
      '$phase failures retain native details without signed URL secrets',
      () async {
        AppLog.shared.clear();
        final failure = StateError(
          'AudioOutputUnitStart failed (OSStatus -666) '
          'https://cdn.example/audio?signature=private-secret',
        );
        final engine = _Engine();
        if (phase == 'open') {
          engine.openFailure = failure;
        } else {
          engine.playFailure = failure;
        }
        final state = stateWith(engine);
        state.playQueue(<Track>[_track]);
        await _until(() => state.playbackError != null);
        final log = AppLog.shared.snapshot();
        expect(log, contains('${phase}_failed'));
        expect(log, contains('OSStatus -666'));
        expect(log, isNot(contains('private-secret')));
        engine.openFailure = null;
        engine.playFailure = null;
        await state.retryPlayback();
        await _until(() => engine.active);
        expect(state.playbackError, isNull);
      },
    );
  }

  for (final queue in [false, true]) {
    test(
      'output refusal is actionable without CDN retry (queue: $queue)',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        AppLog.shared.clear();
        final catalog = _Catalog();
        final engine = queue ? _QueueEngine() : _Engine();
        engine.openFailure = AudioOutputRefused(
          'OSStatus -666 https://cdn.example/audio?signature=private-secret',
        );
        final state = AppState(
          catalog: catalog,
          audioEngine: engine,
          hifiSettings: const HifiSettings(bitPerfect: true),
        );
        addTearDown(state.dispose);
        state.playQueue([_track]);
        await _until(() => state.playbackError != null);
        expect(catalog.resolveCalls, 1);
        if (engine is _QueueEngine) {
          expect(engine.queueCalls, 1);
          expect(
            engine.openCalls,
            0,
            reason: 'a refused queue policy must not retry via setUrl',
          );
        } else {
          expect(engine.openCalls, 1);
        }
        expect(state.playbackError, contains('音频输出设置未能应用'));
        expect(state.playbackError, isNot(contains('OSStatus')));
        expect(state.playbackError, isNot(contains('private-secret')));
        expect(AppLog.shared.snapshot(), contains('OSStatus -666'));
      },
    );
  }

  test('ordinary source StateErrors retain their single CDN retry', () async {
    final catalog = _Catalog();
    final engine = _Engine()
      ..openFailure = StateError('decoder temporarily unavailable');
    final state = AppState(catalog: catalog, audioEngine: engine);
    addTearDown(state.dispose);
    state.playQueue([_track]);
    await _until(() => state.playbackError != null);
    expect(catalog.resolveCalls, 2);
    expect(engine.openCalls, 2);
    expect(state.playbackError, '音频加载失败，请重试。');
  });

  test('audio output recovery stops at the existing retry limit', () async {
    final catalog = _Catalog();
    final engine = _DeviceEngine();
    final state = AppState(
      catalog: catalog,
      audioEngine: engine,
      hifiSettings: const HifiSettings(bitPerfect: true),
    );
    addTearDown(engine.reports.close);
    addTearDown(state.dispose);
    state.playQueue([_track]);
    await _until(() => state.audioReady);
    for (var attempt = 0; attempt < AppState.maxDeviceRetries; attempt++) {
      engine.loseOutput();
      await _until(() => engine.openCalls == attempt + 2 && state.audioReady);
    }
    engine.loseOutput();
    await _until(() => state.playbackError != null);
    expect(engine.openCalls, AppState.maxDeviceRetries + 1);
    expect(catalog.resolveCalls, AppState.maxDeviceRetries + 1);
    expect(state.playing, isFalse);
  });

  test('output recovery refusal does not re-resolve or loop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final catalog = _Catalog();
    final engine = _DeviceEngine();
    final state = AppState(
      catalog: catalog,
      audioEngine: engine,
      hifiSettings: const HifiSettings(bitPerfect: true),
    );
    addTearDown(engine.reports.close);
    addTearDown(state.dispose);
    state.playQueue([_track]);
    await _until(() => state.audioReady);
    engine.openFailure = AudioOutputRefused('output route no longer available');
    engine.loseOutput();
    await _until(() => state.playbackError != null);
    expect(engine.openCalls, 2);
    expect(catalog.resolveCalls, 2);
    expect(state.playbackError, contains('音频输出设置未能应用'));
    expect(state.playing, isFalse);
  });

  for (final String action in <String>['play', 'toggle', 'retry', 'queue']) {
    test(
      '$action requests a new source after the last resolution failed',
      () async {
        final _Catalog catalog = _Catalog()..failResolve = true;
        final _Engine engine = _Engine();
        final AppState state = AppState(catalog: catalog, audioEngine: engine);
        addTearDown(state.dispose);
        state.playQueue(<Track>[_track]);
        await _until(() => state.playbackError != null);
        expect(state.playing, isFalse);
        expect(engine.active, isFalse);
        final int failedRequests = catalog.resolveCalls;

        catalog.failResolve = false;
        switch (action) {
          case 'play':
            state.play();
          case 'toggle':
            state.togglePlay();
          case 'retry':
            await state.retryPlayback();
          case 'queue':
            state.playTrackAt(0);
        }
        await _until(() => engine.active);
        expect(catalog.resolveCalls, greaterThan(failedRequests));
        expect(state.playbackError, isNull);
        expect(state.playing, isTrue);
      },
    );
  }
}
