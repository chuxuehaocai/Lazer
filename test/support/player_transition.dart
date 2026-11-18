import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/widgets.dart';

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

/// Opens the phone's round artwork entry or the desktop transport.
Future<void> tapNowPlayingControl(WidgetTester tester, {String? title}) async {
  final phoneCover = find.byKey(const ValueKey('bottom-track-cover'));
  if (phoneCover.evaluate().isNotEmpty) {
    expect(phoneCover.hitTestable(), findsOneWidget);
    await tester.tap(phoneCover);
    return;
  }
  final Finder bar = find.byType(AppPlayerBar);
  expect(
    bar,
    findsOneWidget,
    reason: 'the shell must expose one now-playing control',
  );
  final target = find.descendant(
    of: bar,
    matching: title == null ? find.byType(AppCover) : find.text(title),
  );
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
}
