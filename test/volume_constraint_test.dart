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
  id: 'volume-fixture',
  title: 'Volume fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'fixture://volume';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

/// Direct output: the engine owns the level and refuses software changes.
class _DirectEngine implements AudioEngine, VolumeConstraintAudioEngine {
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => _track.duration;
  @override
  Stream<void> get completed => const Stream<void>.empty();
  @override
  Future<void> setUrl(String url) async => active = true;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> setVolume(double volume) async {
    // Refused: the stream must stay untouched.
  }

  @override
  Future<void> stop() async => active = false;
  @override
  void dispose() {}

  @override
  double get appliedVolume => 1;

  @override
  String? get volumeNotice => 'direct output';
}

class _SoftwareEngine extends _DirectEngine {
  @override
  Future<void> setVolume(double volume) async => applied = volume.clamp(0, 1);
  double applied = 1;
  @override
  double get appliedVolume => applied;
  @override
  String? get volumeNotice => null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a refused software volume snaps back instead of being persisted', () async {
    final _DirectEngine engine = _DirectEngine();
    final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track]);
    await Future<void>.delayed(Duration.zero);

    await state.setVolume(.2);
    expect(state.volume, 1, reason: 'the engine is still at 100%');
    expect(state.takeVolumeNotice(), isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('lazer_volume'), isNull);
  });

  test('a normal engine still applies and persists the level', () async {
    final _SoftwareEngine engine = _SoftwareEngine();
    final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track]);
    await Future<void>.delayed(Duration.zero);

    await state.setVolume(.3);
    expect(state.volume, closeTo(.3, .0001));
    expect(state.takeVolumeNotice(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('lazer_volume'), closeTo(.3, .0001));
  });
}
