import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/background.dart';

const _track = Track(
  id: 'transport-visibility',
  title: 'A song with lyrics',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _PlaybackState extends AppState {
  _PlaybackState() {
    layoutStyle = AppLayoutStyle.desktop;
    playerBackground = AppBackgroundMode.off;
    lyricControlsSeconds = 1;
    lyrics = const [
      LyricLine(Duration.zero, 'The first lyric'),
      LyricLine(Duration(seconds: 10), 'The second lyric'),
    ];
  }

  bool isPlaying = false;
  int toggles = 0;

  @override
  Track get current => _track;

  @override
  bool get playing => isPlaying;

  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}

  @override
  void playerPresentationChanged(bool visible) {}

  @override
  void togglePlay() {
    toggles++;
    playbackError = null;
    isPlaying = !isPlaying;
    notifyListeners();
  }

  void report({required bool playing, String? error}) {
    isPlaying = playing;
    playbackError = error;
    notifyListeners();
  }
}

Future<void> _mount(WidgetTester tester, _PlaybackState state) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: Brightness.dark),
      home: NowPlayingPage(state: state),
    ),
  );
  await tester.pump();
}

// Allow both the idle timeout and the real dock's hide/reveal animation to run.
Future<void> _idle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'an idle player hides its transport whether or not it is playing',
    (tester) async {
      final state = _PlaybackState();
      await _mount(tester, state);
      final play = find.byKey(const ValueKey('desktop-play-pause'));
      final cover = find.byKey(const ValueKey('now-playing-cover'));

      // A paused player is still an idle one: the transport leaves the canvas
      // instead of pinning itself there until the user resumes.
      await _idle(tester);
      expect(play.hitTestable(), findsNothing);

      // A click on the canvas brings it straight back, so playback stays one
      // press away without a permanently visible dock.
      await tester.tapAt(tester.getCenter(cover));
      await tester.pump();
      // The reveal is a real spring: the dock has no height until it opens.
      await tester.pump(const Duration(milliseconds: 700));
      expect(play.hitTestable(), findsOneWidget);
      await tester.tap(play);
      await tester.pump();
      expect(state.toggles, 1);
      expect(state.playing, isTrue);

      // Active lyric playback still gets its unobstructed presentation.
      await _idle(tester);
      expect(play.hitTestable(), findsNothing);

      // A pause from a system media key does not reveal it either; the same
      // click restores it afterwards.
      state.report(playing: false);
      await tester.pump();
      await _idle(tester);
      expect(play.hitTestable(), findsNothing);
      await tester.tapAt(tester.getCenter(cover));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(play.hitTestable(), findsOneWidget);
      await tester.tap(play);
      await tester.pump();
      expect(state.toggles, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a playback failure reveals the hidden transport for retry', (
    tester,
  ) async {
    final state = _PlaybackState()..isPlaying = true;
    await _mount(tester, state);
    final play = find.byKey(const ValueKey('desktop-play-pause'));
    await _idle(tester);
    expect(play.hitTestable(), findsNothing);

    // An output failure can arrive before the engine's paused notification.
    // The error alone must keep retry controls reachable throughout that gap.
    state.report(playing: true, error: 'Audio output unavailable');
    await tester.pump();
    await _idle(tester);
    expect(play.hitTestable(), findsOneWidget);

    state.report(playing: false, error: 'Audio output unavailable');
    await tester.pump();
    await _idle(tester);
    expect(play.hitTestable(), findsOneWidget);
    await tester.tap(play);
    await tester.pump();
    expect(state.toggles, 1);
    expect(state.playbackError, isNull);
    expect(state.playing, isTrue);
    await _idle(tester);
    expect(play.hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a paused player keeps its ambient canvas flowing', (
    tester,
  ) async {
    final state = _PlaybackState()
      ..playerBackground = AppBackgroundMode.nowPlayingDynamic;
    await _mount(tester, state);

    // Paused: the transport may leave the canvas, but the album flow must not.
    // It used to detach with playback, which froze the whole page visually.
    await tester.pump(const Duration(milliseconds: 200));
    final int ticking = albumFlowClock.debugTicks;
    expect(state.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(albumFlowClock.debugTicks, greaterThan(ticking));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
