import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

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

  testWidgets('the player rises fast and lands slow, and leaves the same way', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    // The browse backdrop would repaint the window behind the player; the
    // motion assertions only care about the player's own offset.
    await state.setLegacyBackground(LegacyBackgroundMode.off);
    state.playQueue(const <Track>[_track]);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    /// How much of the window height the player still has to travel: 1 is
    /// fully below the window, 0 is fully presented.
    double remaining() => tester
        .widget<SlideTransition>(
          find
              .ancestor(
                of: find.byType(NowPlayingPage),
                matching: find.byType(SlideTransition),
              )
              .first,
        )
        .position
        .value
        .dy;

    await tester.tap(
      find.descendant(
        of: find.byType(LegacyPlayerBar),
        matching: find.text(_track.title),
      ),
    );
    await tester.pump();
    expect(remaining(), closeTo(1, .001), reason: 'it starts below the window');

    // First leg of the 400 ms entrance.
    await tester.pump(const Duration(milliseconds: 160));
    final double firstLeg = 1 - remaining();
    expect(
      firstLeg,
      greaterThan(.6),
      reason: 'a decelerating entrance covers most of the travel up front',
    );

    // Second leg: less travel than the first, i.e. it is slowing down.
    await tester.pump(const Duration(milliseconds: 160));
    final double secondLeg = 1 - remaining() - firstLeg;
    expect(secondLeg, lessThan(firstLeg / 2));
    expect(1 - remaining(), greaterThan(.9));

    await tester.pump(const Duration(milliseconds: 220));
    expect(remaining(), closeTo(0, .001));

    // The close is the same curve, reversed: it drops away at once and eases
    // into the bottom edge.
    await tester.tap(find.byKey(const ValueKey('desktop-close')));
    await tester.pump();
    expect(remaining(), closeTo(0, .001));

    await tester.pump(const Duration(milliseconds: 160));
    final double firstLegOut = remaining();
    expect(
      firstLegOut,
      greaterThan(.6),
      reason: 'the exit must not hang at the start either',
    );

    await tester.pump(const Duration(milliseconds: 160));
    final double secondLegOut = remaining() - firstLegOut;
    expect(secondLegOut, lessThan(firstLegOut / 2));

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
