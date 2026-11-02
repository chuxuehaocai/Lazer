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

  testWidgets('the player lands with a symmetric spring before it is removed', (
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

    // A duration/bounce spring has a settling tail, not a fixed 400 ms cutoff.
    await tester.pump(const Duration(milliseconds: 160));
    final double firstLeg = 1 - remaining();
    expect(
      firstLeg,
      inExclusiveRange(.5, 1),
      reason: 'the spring responds promptly without jumping to its endpoint',
    );

    // Second leg: less travel than the first, i.e. it is slowing down.
    await tester.pump(const Duration(milliseconds: 160));
    final double secondLeg = 1 - remaining() - firstLeg;
    expect(secondLeg, inExclusiveRange(0, firstLeg));
    expect(1 - remaining(), greaterThan(.9));

    await pumpPlayerTransition(tester, motion, AnimationStatus.completed);
    expect(remaining(), closeTo(0, .001));

    // The close starts from rest with the same spring in the other direction.
    await tester.tap(find.byKey(const ValueKey('desktop-close')));
    await tester.pump();
    expect(remaining(), closeTo(0, .001));

    await tester.pump(const Duration(milliseconds: 160));
    final double firstLegOut = remaining();
    expect(
      firstLegOut,
      closeTo(firstLeg, .001),
      reason: 'opening and closing share the same physical response',
    );

    await tester.pump(const Duration(milliseconds: 160));
    final double secondLegOut = remaining() - firstLegOut;
    expect(secondLegOut, closeTo(secondLeg, .001));

    await pumpPlayerTransition(tester, motion, AnimationStatus.dismissed);
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
