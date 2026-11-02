import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';

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
/// player spring itself, retaining a bounded failure for a motion that stalls.
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
    reason: 'The player spring must finish within $deadline.',
  );
  await tester.pump();
}
