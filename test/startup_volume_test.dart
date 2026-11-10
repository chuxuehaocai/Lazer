import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

class _Engine implements AudioEngine {
  final events = <String>[];
  double volume = 1;
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setVolume(double value) async {
    volume = value;
    events.add('volume:$value');
  }

  @override
  Future<void> setUrl(String url) async {
    events.add('open:$volume');
    active = true;
  }

  @override
  Future<void> play() async {
    events.add('play:$volume');
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration next) async {
    position = next;
  }

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  void dispose() {}
}

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => 'file:///fixture.mp3';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

const track = Track(
  id: 'local:volume',
  title: 'Volume',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 0,
);
void main() {
  for (final target in [0.0, .02, .5]) {
    testWidgets(
      'first source and play honor saved volume $target before bootstrap',
      (tester) async {
        SharedPreferences.setMockInitialValues({'lazer_volume': target});
        final engine = _Engine();
        final state = AppState(
          catalog: _Catalog(),
          audioEngine: engine,
          artworkSeedLoader: (_) async => null,
        );
        addTearDown(state.dispose);
        state.playQueue([track]);
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }
        expect(engine.events.first, 'volume:$target');
        expect(engine.events, contains('open:$target'));
        expect(engine.events, contains('play:$target'));
        state.pause();
      },
    );
  }
  testWidgets('a manual startup volume change wins over the saved setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'lazer_volume': .8});
    final engine = _Engine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      artworkSeedLoader: (_) async => null,
    );
    addTearDown(state.dispose);
    state.playQueue([track]);
    state.previewVolume(.1);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(engine.events, contains('open:0.1'));
    expect(engine.events, contains('play:0.1'));
    expect(state.volume, .1);
    state.pause();
  });
}
