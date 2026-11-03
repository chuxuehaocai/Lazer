import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

import 'support/player_transition.dart';

const Track _track = Track(
  id: 'motion-fixture',
  title: 'Motion fixture',
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
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]First lyric\n[00:05.00]Second lyric');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('desktop entrance and exit finish with a calm finite slide', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    // The browse backdrop would repaint the window behind the player; the
    // motion assertions only care about the player's own offset.
    await state.setAppBackground(AppBackgroundMode.off);
    state.playQueue(const <Track>[_track]);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: AppShell(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    /// How much of the window height the player still has to travel: 1 is
    /// fully below the window, 0 is fully presented.
    double remaining() => playerSlideAnimation(tester).value.dy;

    await tester.tap(
      find.descendant(
        of: find.byType(AppPlayerBar),
        matching: find.text(_track.title),
      ),
    );
    await tester.pump();
    expect(remaining(), closeTo(1, .001), reason: 'it starts below the window');

    final motion = playerSlideAnimation(tester);
    expect(motion.status, AnimationStatus.forward);

    await tester.pump(const Duration(milliseconds: 160));
    final double firstLeg = 1 - remaining();
    expect(
      firstLeg,
      inExclusiveRange(.2, .4),
      reason: 'the full page eases in instead of rushing through its first leg',
    );

    await tester.pump(const Duration(milliseconds: 160));
    final double secondLeg = 1 - remaining() - firstLeg;
    expect(secondLeg, greaterThan(firstLeg));
    expect(1 - remaining(), inExclusiveRange(.7, .9));

    await tester.pump(const Duration(milliseconds: 140));
    expect(remaining(), closeTo(0, .001));
    expect(motion.status, AnimationStatus.completed);

    // Closing has the same pace and no almost-stationary spring tail.
    await tester.tap(find.byKey(const ValueKey('desktop-close')));
    await tester.pump();
    expect(remaining(), closeTo(0, .001));

    await tester.pump(const Duration(milliseconds: 160));
    final double firstLegOut = remaining();
    expect(
      firstLegOut,
      closeTo(firstLeg, .001),
      reason: 'opening and closing share the same deliberate pace',
    );

    await tester.pump(const Duration(milliseconds: 160));
    final double secondLegOut = remaining() - firstLegOut;
    expect(secondLegOut, closeTo(secondLeg, .001));

    await tester.pump(const Duration(milliseconds: 140));
    await tester.pump();
    expect(motion.status, AnimationStatus.dismissed);
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop open, close and reopen keep the same moving page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppBackground(AppBackgroundMode.off);
    await state.setPlayerBackground(AppBackgroundMode.off);
    state.playQueue(const [_track]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: AppShell(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    final open = tester.widget<AppPlayerBar>(find.byType(AppPlayerBar)).onOpen;
    open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final page = tester.element(find.byType(NowPlayingPage));
    final motion = playerSlideAnimation(tester);
    final beforeClose = motion.value.dy;
    tester.widget<NowPlayingPage>(find.byType(NowPlayingPage)).onClose!();
    expect(motion.value.dy, beforeClose);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(motion.value.dy, lessThan(beforeClose));
    await tester.pump(const Duration(milliseconds: 130));
    final beforeReopen = motion.value.dy;
    open();
    expect(motion.value.dy, beforeReopen);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(motion.value.dy, greaterThan(beforeReopen));
    await pumpPlayerTransition(tester, motion, AnimationStatus.completed);
    expect(tester.element(find.byType(NowPlayingPage)), same(page));
    expect(motion.value.dy, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
