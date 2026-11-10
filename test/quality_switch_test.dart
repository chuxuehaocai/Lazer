import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Track _track = Track(
  id: 'fixture',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _QualityCatalog extends Catalog {
  final List<AudioQuality> requests = <AudioQuality>[];

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
    bool Function()? isCancelled,
  }) async {
    requests.add(quality);
    return AudioSource(url: 'quality://${quality.name}', quality: quality);
  }

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:01.00]line');
}

class _Engine implements AudioEngine {
  final List<String> urls = <String>[];
  final List<Duration> seeks = <Duration>[];
  double volume = 1;

  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => _track.duration;

  @override
  Stream<void> get completed => const Stream<void>.empty();

  @override
  Future<void> setUrl(String url) async {
    urls.add(url);
    active = true;
    position = Duration.zero;
  }

  @override
  Future<void> setVolume(double value) async => volume = value;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    position = value;
  }

  @override
  Future<void> stop() async => active = false;

  @override
  void dispose() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('switching quality reloads the current track at the playhead', () async {
    final _QualityCatalog catalog = _QualityCatalog();
    final _Engine engine = _Engine();
    final AppState state = AppState(catalog: catalog, audioEngine: engine);
    addTearDown(state.dispose);

    state.playQueue(const <Track>[_track]);
    await _waitUntil(() => engine.urls.length == 1, 'first load');
    expect(engine.urls.single, 'quality://exhigh');

    state.seek(30 / _track.duration.inSeconds);
    expect(engine.seeks.last, const Duration(seconds: 30));

    await state.setPlaybackQuality(AudioQuality.lossless);
    await _waitUntil(() => engine.urls.length == 2, 'quality reload');

    expect(state.playbackQuality, AudioQuality.lossless);
    expect(engine.urls.last, 'quality://lossless');
    expect(engine.seeks.last, const Duration(seconds: 30));
    expect(state.position, const Duration(seconds: 30));
    expect(state.playing, isTrue);
    expect(catalog.requests.last, AudioQuality.lossless);
  });

  test('the chosen quality survives a restart', () async {
    final AppState state = AppState(catalog: _QualityCatalog());
    addTearDown(state.dispose);
    await state.setPlaybackQuality(AudioQuality.higher);
    await state.setDownloadQuality(AudioQuality.standard);

    final AppState restored = AppState(catalog: _QualityCatalog());
    addTearDown(restored.dispose);
    await restored.bootstrap();

    expect(restored.playbackQuality, AudioQuality.higher);
    expect(restored.downloadQuality, AudioQuality.standard);
  });
}

Future<void> _waitUntil(bool Function() predicate, String reason) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
