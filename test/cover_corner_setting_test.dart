import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/navigation/pull_down_to_close.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/theme/shape_scale.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track() => const Track(
  id: 'corner',
  title: 'A song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 3,
);

class _CornerState extends AppState {
  _CornerState({required double cornerPx}) {
    layoutStyle = AppLayoutStyle.phone;
    playerBackground = AppBackgroundMode.off;
    cornerFollowsTheme = false;
    this.cornerPx = cornerPx;
  }

  @override
  Track get current => _track();

  @override
  bool get playing => false;

  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}

  @override
  void playerPresentationChanged(bool visible) {}
}

class _PullDown extends PlayerPullDown {
  @override
  bool get canStart => true;
  @override
  void startPull() {}
  @override
  void updatePull(double progress) {}
  @override
  void endPull(double velocity) {}
}

/// The radius the cover's artwork is actually clipped to.
double _coverClipRadius(WidgetTester tester) {
  final Finder cover = find.byKey(const ValueKey('now-playing-cover'));
  // The clip wraps the cover, it is not inside it: `now-playing-cover` is the
  // KeyedSubtree the ClipRRect cuts.
  final Finder clip = find.ancestor(
    of: cover,
    matching: find.byType(ClipRRect),
  );
  expect(clip, findsWidgets);
  return tester
      .widget<ClipRRect>(clip.first)
      .borderRadius
      .resolve(TextDirection.ltr)
      .topLeft
      .x;
}

Future<void> _mount(WidgetTester tester, _CornerState state) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(state.dispose);
  // The app supplies this above the window frame; a bare `NowPlayingPage` has no
  // provider, and without it every `cardRadiusOf` silently falls back to the
  // skin token — which is exactly how the corner setting managed to be ignored
  // without anyone noticing.
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: Brightness.dark),
      home: AppleShape(
        scale: AppleShape.resolve(
          followTheme: state.cornerFollowsTheme,
          customPx: state.cornerPx,
          theme: LazerThemeTokens.mio,
        ),
        cardPx: state.cornerPx,
        manual: !state.cornerFollowsTheme,
        capsulePx: 0,
        navBarPx: 0,
        child: NowPlayingPage(state: state, pullDown: _PullDown()),
      ),
    ),
  );
  await tester.pump();
  // The cover rides an AnimatedContainer; wait for its first frame to land so the
  // clip reflects the corner this mount asked for rather than the previous one.
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final double cornerPx in <double>[0, 8, 20]) {
    testWidgets('the player cover is clipped with $cornerPx px corner', (
      tester,
    ) async {
      // The box that draws the cover's shadow already read `_coverRadius`; the
      // ClipRRect that actually cuts the artwork was hard-coded to 12, and a clip
      // wins over the decoration. So the corner setting never reached the
      // picture: the cover stayed square whatever the listener picked.
      final state = _CornerState(cornerPx: cornerPx);
      await _mount(tester, state);
      expect(
        _coverClipRadius(tester),
        closeTo(cornerPx, .01),
        reason: 'the artwork clip has to follow the corner setting',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a zero corner really squares the player cover', (tester) async {
    final state = _CornerState(cornerPx: 0);
    await _mount(tester, state);
    expect(_coverClipRadius(tester), 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the chart row highlight follows the configured corner', (
    tester,
  ) async {
    // The hover highlight is the row's `ListTile.shape`. It was hard-coded to
    // `8 * scaleOf`, so the highlight kept one corner size no matter what the
    // listener configured. Chart rows sit under the same shape provider as every
    // other card, so the highlight has to move with it.
    for (final double cornerPx in <double>[0, 12, 28]) {
      final state = _CornerState(cornerPx: cornerPx);
      await _mount(tester, state);
      final BuildContext context = tester.element(
        find.byKey(const ValueKey('now-playing-cover')),
      );
      expect(
        AppleShape.cardRadiusOf(context, LazerThemeTokens.of(context)),
        closeTo(cornerPx, .01),
        reason: 'the row highlight radius has to follow the setting',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
