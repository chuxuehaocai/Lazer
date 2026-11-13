import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';

Animation<Offset> playerSlideAnimation(WidgetTester tester) => tester
    .widget<SlideTransition>(
      find
          .ancestor(
            of: find.byType(NowPlayingPage),
            matching: find.byType(SlideTransition),
          )
          .first,
    )
    .position;

/// Ambient flow and lyric tickers can outlive the transition. Wait for the
/// player motion itself, retaining a bounded failure for a motion that stalls.
Future<void> pumpPlayerTransition(
  WidgetTester tester,
  Animation<Offset> motion,
  AnimationStatus destination, {
  VoidCallback? onMovingFrame,
}) async {
  const frame = Duration(milliseconds: 16);
  const deadline = Duration(milliseconds: 1500);
  var elapsed = Duration.zero;
  while (motion.status != destination && elapsed < deadline) {
    onMovingFrame?.call();
    await tester.pump(frame);
    elapsed += frame;
  }
  expect(
    motion.status,
    destination,
    reason: 'The player transition must finish within $deadline.',
  );
  await tester.pump();
}

/// Taps whatever the shell presents as its now-playing control: the transport
/// bar on windows wide enough for it, otherwise the cover beside the capsule.
Future<void> tapNowPlayingControl(WidgetTester tester, {String? title}) async {
  final Finder cover = find.byKey(const ValueKey<String>('bottom-track-cover'));
  if (cover.evaluate().isNotEmpty) {
    await tester.tap(cover);
    return;
  }
  final Finder bar = find.byType(AppPlayerBar);
  expect(
    bar,
    findsOneWidget,
    reason: 'the shell must expose one now-playing control',
  );
  await tester.tap(
    title == null ? bar : find.descendant(of: bar, matching: find.text(title)),
  );
}
