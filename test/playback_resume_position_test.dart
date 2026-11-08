import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: 'resume-fixture',
  title: 'Resume fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 4),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'fixture://resume';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

class _Engine implements AudioEngine {
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
  Future<void> setUrl(String url) async => active = true;
  @override
  Future<void> play() async {}
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
}
