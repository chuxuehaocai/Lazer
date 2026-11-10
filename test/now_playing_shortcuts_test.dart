import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: 'shortcut-fixture',
  title: 'Shortcut fixture',
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
    bool Function()? isCancelled,
  }) async => 'fixture://shortcut';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

class _Engine implements AudioEngine {
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
  Future<void> setUrl(String url) async => active = true;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> setVolume(double value) async => volume = value;
  @override
  Future<void> stop() async => active = false;
  @override
  void dispose() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the player answers its advertised bare-key shortcuts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Engine engine = _Engine();
    final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track]);
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(home: NowPlayingPage(state: state, onClose: () => closed = true)),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(state.volume, 0, reason: 'M must mute');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(state.volume, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, isTrue, reason: 'Esc must close the player');
    expect(tester.takeException(), isNull);
    state.pause();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
