import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';

const _artworkKey = ValueKey('layout-artwork');
const _lyricsKey = ValueKey('layout-lyrics');
const _detailsKey = ValueKey('layout-details');
const _transportKey = ValueKey('layout-transport');
const _summaryKey = ValueKey('layout-summary');

Widget _layout({
  required bool lyrics,
  bool controls = true,
  bool reduced = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: Scaffold(
    body: SafeArea(
      child: ArtworkLyricsLayout(
        lyricsVisible: lyrics,
        controlsVisible: controls,
        header: const SizedBox(height: 56),
        summary: const SizedBox(key: _summaryKey, height: 56),
        artwork: const ColoredBox(key: _artworkKey, color: Colors.blue),
        lyrics: const ColoredBox(key: _lyricsKey, color: Colors.black),
        details: const SizedBox(key: _detailsKey, height: 64),
        transport: const SizedBox(key: _transportKey, height: 144),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'top summary enters downward and exits upward from its current pose',
    (tester) async {
      await tester.pumpWidget(_layout(lyrics: true));
      final summary = find.byKey(_summaryKey);
      final fade = find.byKey(const ValueKey('compact-player-summary-fade'));
      final hiddenTop = tester.getTopLeft(summary).dy;
      await tester.pumpWidget(_layout(lyrics: true, controls: false));
      await tester.pump(const Duration(milliseconds: 80));
      final enteringTop = tester.getTopLeft(summary).dy;
      expect(enteringTop, greaterThan(hiddenTop));
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      final restingTop = tester.getTopLeft(summary).dy;
      expect(restingTop, greaterThan(enteringTop));
      await tester.pumpWidget(_layout(lyrics: true, controls: true));
      expect(tester.getTopLeft(summary).dy, closeTo(restingTop, .0001));
      await tester.pump(const Duration(milliseconds: 100));
      final exitingTop = tester.getTopLeft(summary).dy;
      final exitingOpacity = tester.widget<FadeTransition>(fade).opacity.value;
      expect(exitingTop, lessThan(restingTop));
      expect(exitingOpacity, inExclusiveRange(0, 1));
      await tester.pumpWidget(_layout(lyrics: true, controls: false));
      expect(tester.getTopLeft(summary).dy, closeTo(exitingTop, .0001));
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        closeTo(exitingOpacity, .0001),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(summary).dy, closeTo(restingTop, .0001));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('artwork mode reverses with its current position and velocity', (
    tester,
  ) async {
    await tester.pumpWidget(_layout(lyrics: false));
    final art = find.byKey(_artworkKey);
    final element = tester.element(art);
    await tester.pumpWidget(_layout(lyrics: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(_lyricsKey),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    final mode = fade.opacity as AnimationController;
    final value = mode.value, velocity = mode.velocity;
    final bounds = tester.getRect(art);
    expect(velocity, greaterThan(0));
    await tester.pumpWidget(_layout(lyrics: false));
    expect(tester.element(art), same(element));
    expect(
      (tester.getRect(art).topLeft - bounds.topLeft).distance,
      lessThan(.001),
    );
    expect(
      (tester.getRect(art).bottomRight - bounds.bottomRight).distance,
      lessThan(.001),
    );
    expect(mode.value, closeTo(value, .000001));
    expect(mode.velocity, closeTo(velocity, .000001));
    await tester.pump(const Duration(milliseconds: 1));
    expect(mode.value, greaterThan(value));
    await tester.pumpAndSettle();
    expect(mode.value, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'reduced motion finishes a running artwork and chrome transition',
    (tester) async {
      await tester.pumpWidget(_layout(lyrics: false));
      await tester.pumpWidget(_layout(lyrics: true, controls: false));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.pumpWidget(
        _layout(lyrics: true, controls: false, reduced: true),
      );
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932),
    const Size(700, 1024),
    const Size(568, 320),
    const Size(844, 390),
  ]) {
    testWidgets('mobile artwork and transport stay separated at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_layout(lyrics: false));
      final art = find.byKey(_artworkKey);
      final element = tester.element(art);
      final large = tester.getRect(art);
      final details = tester.getRect(find.byKey(_detailsKey));
      final transport = tester.getRect(find.byKey(_transportKey));
      final landscape = size.width > size.height;

      expect(large.width, closeTo(large.height, .01));
      expect(large.shortestSide, greaterThan(100));
      if (landscape) {
        expect(large.right, lessThan(transport.left));
        if (details.left < transport.left) {
          expect(large.bottom, lessThan(details.top));
          expect(details.right, lessThan(transport.left));
        } else {
          expect(large.right, lessThan(details.left));
          expect(details.left, closeTo(transport.left, .01));
          expect(details.right, closeTo(transport.right, .01));
        }
      } else {
        expect(large.bottom, lessThan(details.top));
        expect(transport.width, lessThanOrEqualTo(440));
      }
      expect(details.overlaps(transport), isFalse);

      await tester.pumpWidget(_layout(lyrics: true));
      await tester.pumpAndSettle();
      expect(tester.element(art), same(element));
      final small = tester.getRect(art);
      final compactDetails = tester.getRect(find.byKey(_detailsKey));
      final compactTransport = tester.getRect(find.byKey(_transportKey));
      final lyrics = tester.getRect(find.byKey(_lyricsKey));
      expect(small.width, closeTo(64, 1));
      expect(small.center.dy, closeTo(compactDetails.center.dy, .01));
      expect(small.right, lessThan(compactDetails.left));
      expect(lyrics.bottom, lessThanOrEqualTo(small.top));
      expect(lyrics.bottom, lessThanOrEqualTo(compactDetails.top));
      expect(compactDetails.right, lessThanOrEqualTo(compactTransport.right));
      if (landscape) {
        expect(compactDetails.right, lessThan(compactTransport.left));
      } else {
        expect(small.left, closeTo(compactTransport.left, .01));
        expect(compactDetails.bottom, lessThan(compactTransport.top));
      }

      await tester.pumpWidget(_layout(lyrics: true, controls: false));
      await tester.pumpAndSettle();
      final expandedLyrics = tester.getRect(find.byKey(_lyricsKey));
      expect(expandedLyrics.height, greaterThan(lyrics.height));
      final content = tester.getRect(
        find.byKey(const ValueKey('artwork-lyrics-content')),
      );
      expect(expandedLyrics.height, greaterThanOrEqualTo(content.height - 12));
      expect(tester.takeException(), isNull);
    });
  }
}
