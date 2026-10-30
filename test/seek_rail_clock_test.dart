import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/player_seek_bar.dart';

const Track _track = Track(
  id: 'seek-fixture',
  title: 'Seek fixture',
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
  }) async => 'fixture://seek';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

/// A transport whose position only moves when the test says so: the engine
/// clock is the live value, the 100 ms transport tick is a snapshot of it.
class _Engine implements AudioEngine {
  bool delaySeeks = false;
  final List<Duration> seekRequests = [];
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
  Future<void> seek(Duration value) async {
    seekRequests.add(value);
    if (!delaySeeks) position = value;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async => active = false;
  @override
  void dispose() {}
}

Future<AppState> _pumpPlayer(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Engine engine = _Engine();
  final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
  addTearDown(state.dispose);
  state.playQueue(<Track>[_track]);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLegacyTheme(),
      home: NowPlayingPage(state: state),
    ),
  );
  await tester.pump();
  expect(engine.active, isTrue, reason: 'the fixture stream must be loaded');
  return state;
}

/// A structural change rebuilds the page without advancing the fake clock, so
/// the 100 ms transport tick cannot have copied the engine position across.
Future<void> _rebuildWithoutTick(WidgetTester tester, AppState state) async {
  state.toggleShuffle();
  await tester.pump();
}

/// The slider inside the seek rail: the desktop page also mounts a volume
/// slider, so a bare `find.byType(Slider)` is ambiguous.
Finder _railSlider() => find.descendant(
  of: find.byType(PlayerSeekBar),
  matching: find.byType(Slider),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'dragging holds the preview across ticks and seeks once without flashing back',
    (tester) async {
      final state = await _pumpPlayer(tester, const Size(390, 844));
      final engine = state.audioEngine! as _Engine;
      engine.delaySeeks = true;
      engine.seekRequests.clear();
      engine.position = const Duration(seconds: 20);
      await _rebuildWithoutTick(tester, state);
      final rect = tester.getRect(_railSlider());
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * .3, rect.center.dy),
      );
      await gesture.moveTo(Offset(rect.left + rect.width * .7, rect.center.dy));
      await tester.pump();
      final preview = tester.widget<Slider>(_railSlider()).value;
      expect(preview, greaterThan(.5));
      engine.position = const Duration(seconds: 21);
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        tester.widget<Slider>(_railSlider()).value,
        closeTo(preview, .001),
      );
      expect(engine.seekRequests, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(engine.seekRequests, hasLength(1));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester.widget<Slider>(_railSlider()).value,
        closeTo(preview, .001),
      );
      engine.position =
          engine.seekRequests.single + const Duration(milliseconds: 250);
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.widget<Slider>(_railSlider()).value,
        closeTo(
          engine.position.inMilliseconds / _track.duration.inMilliseconds,
          .001,
        ),
      );
      expect(tester.takeException(), isNull);
      state.pause();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the phone rail and elapsed time follow the engine clock', (
    tester,
  ) async {
    final AppState state = await _pumpPlayer(tester, const Size(390, 844));
    final _Engine engine = state.audioEngine! as _Engine;
    engine.position = const Duration(minutes: 1);
    await _rebuildWithoutTick(tester, state);

    expect(
      state.position,
      Duration.zero,
      reason: 'no transport tick has fired yet, the snapshot is still zero',
    );
    expect(state.progress, closeTo(.25, 1e-9));
    expect(
      tester.widget<Slider>(_railSlider()).value,
      closeTo(.25, 1e-9),
      reason: 'the rail must paint the engine clock, not the tick snapshot',
    );
    expect(find.byType(PlayerSeekBar), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);

    state.pause();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the desktop rail and elapsed time follow the engine clock', (
    tester,
  ) async {
    final AppState state = await _pumpPlayer(tester, const Size(1280, 800));
    final _Engine engine = state.audioEngine! as _Engine;
    engine.position = const Duration(seconds: 90);
    await _rebuildWithoutTick(tester, state);

    expect(state.position, Duration.zero);
    expect(state.progress, closeTo(.375, 1e-9));
    expect(tester.widget<Slider>(_railSlider()).value, closeTo(.375, 1e-9));
    expect(find.byKey(const ValueKey('desktop-seek-bar')), findsOneWidget);
    expect(find.text('1:30'), findsOneWidget);

    state.pause();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
