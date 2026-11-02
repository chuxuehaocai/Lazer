import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/ui/background.dart';

void main() {
  for (final refresh in [60.0, 120.0, 165.0]) {
    for (final rate in [10.0, 30.0]) {
      testWidgets('$rate fps requests only due frames on $refresh Hz', (
        tester,
      ) async {
        tester.view.display.refreshRate = refresh;
        addTearDown(tester.view.display.resetRefreshRate);
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumFlowBackground(
              colors: albumFlowColors(Colors.blue),
              frameRate: rate,
            ),
          ),
        );
        await tester.pump();
        final ticks = albumFlowClock.debugTicks;
        final renders = albumFlowRenderer.debugFrameBuilds;
        final period = Duration(microseconds: (1000000 / refresh).round());
        for (var frame = 0; frame < refresh.toInt() * 2; frame++) {
          await tester.pump(period);
        }
        final delivered = albumFlowClock.debugTicks - ticks;
        final painted = albumFlowRenderer.debugFrameBuilds - renders;
        expect(
          delivered,
          inInclusiveRange((rate * 2).toInt() - 2, (rate * 2).toInt() + 2),
        );
        expect(
          painted,
          inInclusiveRange((rate * 2).toInt() - 2, (rate * 2).toInt() + 2),
        );
        debugPrint(
          '$refresh Hz / $rate fps: ${refresh.toInt() * 2} '
          'display pulses, $delivered background callbacks, $painted paints',
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(albumFlowClock.debugTicks, ticks + delivered);
        expect(tester.binding.hasScheduledFrame, isFalse);
      });
    }
  }

  testWidgets('fast visible consumers update the shared wake schedule', (
    tester,
  ) async {
    Widget page(double? rate, {bool fastVisible = true}) => MaterialApp(
      home: Row(
        children: [
          Expanded(
            child: AlbumFlowBackground(
              colors: albumFlowColors(Colors.blue),
              frameRate: rate,
            ),
          ),
          Expanded(
            child: TickerMode(
              enabled: fastVisible,
              child: AlbumFlowBackground(
                colors: albumFlowColors(Colors.red),
                frameRate: null,
              ),
            ),
          ),
        ],
      ),
    );
    Future<int> ticksOverSecond() async {
      final before = albumFlowClock.debugTicks;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      return albumFlowClock.debugTicks - before;
    }

    await tester.pumpWidget(page(10));
    expect(await ticksOverSecond(), inInclusiveRange(58, 60));
    await tester.pumpWidget(page(10, fastVisible: false));
    expect(await ticksOverSecond(), inInclusiveRange(9, 11));
    await tester.pumpWidget(page(30, fastVisible: false));
    expect(await ticksOverSecond(), inInclusiveRange(29, 31));
    await tester.pumpWidget(page(30));
    expect(await ticksOverSecond(), inInclusiveRange(58, 60));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('inactive apps cancel wakeups and retain the shared phase', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AlbumFlowBackground(
          colors: albumFlowColors(Colors.blue),
          frameRate: 10,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    final phase = albumFlowClock.elapsed;
    final ticks = albumFlowClock.debugTicks;
    await tester.pump(const Duration(seconds: 5));
    expect(albumFlowClock.elapsed, phase);
    expect(albumFlowClock.debugTicks, ticks);
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      albumFlowClock.elapsed - phase,
      lessThan(const Duration(milliseconds: 250)),
    );
    expect(albumFlowClock.debugTicks, greaterThan(ticks));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
