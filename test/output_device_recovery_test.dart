import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => 'https://cdn.test/${track.id}.mp3';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Track _track(String id) => Track(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

/// An engine whose output device the platform can take back, the way Android
/// reclaims a shared-mode stream when another application asks for the output.
class _DeviceEngine
    implements
        AudioEngine,
        BufferedAudioEngine,
        StartupBufferReportingAudioEngine,
        QueueAudioEngine,
        FailureReportingAudioEngine,
        InterruptionYieldingAudioEngine {
  final StreamController<AudioFailure> _failures =
      StreamController<AudioFailure>.broadcast();
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<int> _indexes = StreamController<int>.broadcast();
  final List<String> loaded = <String>[];

  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 3);

  int plays = 0;
  int stops = 0;
  Duration? lastSeek;

  /// Set to model a device that refuses every open.
  bool refuseLoads = false;

  @override
  Stream<AudioFailure> get failures => _failures.stream;

  @override
  AudioFailure? get pendingFailure => null;

  void report(AudioFailure failure) => _failures.add(failure);

  @override
  Future<void> setUrl(String url) async {
    if (refuseLoads) throw StateError('no output device');
    loaded.add(url);
    active = true;
  }

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    await setUrl(urls[startIndex]);
    return 1;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async => false;

  @override
  Future<bool> playQueuedNext() async => false;

  @override
  Stream<int> get indexStream => _indexes.stream;

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async => lastSeek = value;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    stops++;
    active = false;
  }

  @override
  Duration get bufferedPosition => position;

  /// Unknown on purpose: a stream whose lead cannot be measured is started at
  /// once rather than held for a fraction it can never report.
  @override
  Duration? get startupBufferedPosition => null;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  void dispose() {
    _failures.close();
    _completed.close();
    _indexes.close();
  }
}

/// Lets the load path and the transport tick run.
Future<void> _settle([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a reclaimed output device is reopened at the position it reached',
    () async {
      final engine = _DeviceEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track('a')]);
      await _settle();
      expect(engine.loaded, <String>['https://cdn.test/a.mp3']);
      expect(state.audioReady, isTrue);
      final int playsBefore = engine.plays;

      engine.position = const Duration(seconds: 42);
      await _until(() => state.position == const Duration(seconds: 42));

      // Another application takes the output: the engine's session is gone.
      engine.report(
        const AudioFailure('the output device was lost', AudioFailureKind.device),
      );

      await _until(() => engine.loaded.length == 2);
      expect(
        engine.loaded,
        <String>['https://cdn.test/a.mp3', 'https://cdn.test/a.mp3'],
        reason: 'the same track is opened on a fresh device',
      );
      expect(
        engine.lastSeek,
        const Duration(seconds: 42),
        reason: 'the playhead survives the reopen',
      );
      expect(
        state.playbackError,
        isNull,
        reason: 'a reclaimed device is not a failure of the track',
      );
      expect(state.playing, isTrue);
      expect(
        engine.plays,
        greaterThan(playsBefore),
        reason: 'playback resumes on the new device',
      );
    },
  );

  test('a device that never comes back ends in a named failure', () async {
    final engine = _DeviceEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      startupByteTarget: 0,
    );
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await _settle();

    engine.refuseLoads = true;
    engine.report(
      const AudioFailure('the output device was lost', AudioFailureKind.device),
    );
    await _until(() => !state.playing);

    expect(state.playing, isFalse);
    expect(state.playbackError, isNotNull);
    expect(
      state.hifiPathNotice,
      contains('the output device was lost'),
      reason: 'the device cause stays visible even when the reopen fails',
    );
  });

  test('a decode failure is not a device failure: nothing is reopened', () async {
    final engine = _DeviceEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      startupByteTarget: 0,
    );
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await _settle();

    engine.report(
      const AudioFailure('playback failed (decode error)', AudioFailureKind.decode),
    );
    await _until(() => !state.playing);

    expect(
      engine.loaded,
      <String>['https://cdn.test/a.mp3'],
      reason: 'a second decode would fail identically',
    );
    expect(state.playbackError, 'playback failed (decode error)');
  });

  test('the device retry budget is bounded', () async {
    final engine = _DeviceEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      startupByteTarget: 0,
    );
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await _settle();

    // Every open comes up and dies again: the app must stop reopening and name
    // the failure instead of looping forever.
    for (var round = 0; round < AppState.maxDeviceRetries + 2; round++) {
      engine.report(
        const AudioFailure('the output device was lost', AudioFailureKind.device),
      );
      await _settle();
    }
    await _until(() => !state.playing);
    await _settle();

    expect(state.playing, isFalse);
    expect(state.playbackError, isNotNull);
  });
}
