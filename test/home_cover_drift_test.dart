import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/ui/home_pages.dart';

Widget _card({required bool tickersEnabled, bool compact = false}) =>
    MaterialApp(
      home: TickerMode(
        enabled: tickersEnabled,
        child: Center(
          child: FilledCoverCard(
            width: 240,
            height: 160,
            title: 'Daily',
            detail: 'Today',
            icon: Icons.calendar_today_rounded,
            compact: compact,
            covers: const <String?>[
              'https://example.test/a.jpg',
              'https://example.test/b.jpg',
              'https://example.test/c.jpg',
            ],
          ),
        ),
      ),
    );

double _drift(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const ValueKey<String>('cover-mosaic-drift')))
    .transform
    .getTranslation()
    .x;

double _phoneDrift(WidgetTester tester) => tester
    .widget<Transform>(
      find.byKey(const ValueKey<String>('phone-cover-mosaic-drift')),
    )
    .transform
    .getTranslation()
    .x;

void main() {
  testWidgets('the card collage drifts instead of sitting still', (
    tester,
  ) async {
    await tester.pumpWidget(_card(tickersEnabled: true));
    await tester.pump();

    final start = _drift(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      _drift(tester),
      isNot(closeTo(start, .01)),
      reason: 'the artwork strip keeps moving under the labels',
    );

    // Unmount so the drift timer is cancelled before the test ends.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a muted card stops its timer', (tester) async {
    await tester.pumpWidget(_card(tickersEnabled: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // A retained page that is not on screen mutes tickers; the card must stop
    // paying for a timer nobody can see.
    await tester.pumpWidget(_card(tickersEnabled: false));
    await tester.pump();
    final frozen = _drift(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      _drift(tester),
      closeTo(frozen, .001),
      reason: 'no frame is produced while the tree is muted',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the phone card collage drifts too', (tester) async {
    // The daily-recommendation cards and the chart covers used to freeze on a
    // phone: the compact layout painted a static grid while every other cover in
    // the app animated. Same drift, same stop conditions, just laid out as the
    // tiles that actually cover the card.
    await tester.pumpWidget(_card(tickersEnabled: true, compact: true));
    await tester.pump();

    final start = _phoneDrift(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      _phoneDrift(tester),
      isNot(closeTo(start, .01)),
      reason: 'the compact collage keeps moving under the labels',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a muted phone card stops its timer', (tester) async {
    await tester.pumpWidget(_card(tickersEnabled: true, compact: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(_card(tickersEnabled: false, compact: true));
    await tester.pump();
    final frozen = _phoneDrift(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      _phoneDrift(tester),
      closeTo(frozen, .001),
      reason: 'the compact collage keeps no timer nobody can see either',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('reduced motion freezes the phone collage', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _card(tickersEnabled: true, compact: true),
      ),
    );
    await tester.pump();
    final frozen = _phoneDrift(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      _phoneDrift(tester),
      closeTo(frozen, .001),
      reason: 'the platform asked for less motion',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
