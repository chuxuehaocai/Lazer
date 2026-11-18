import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/navigation/pull_down_to_close.dart';

class _PullHost implements PlayerPullDown {
  bool pulling = false;
  bool available = true;
  int starts = 0, ends = 0, cancels = 0;
  final List<double> updates = [];

  @override
  bool get canStart => available && !pulling;

  @override
  void startPull() {
    starts++;
    pulling = true;
  }

  @override
  void updatePull(double progress) => updates.add(progress);

  @override
  void endPull(double velocity) {
    ends++;
    pulling = false;
  }

  @override
  void cancelPull() {
    cancels++;
    pulling = false;
  }
}

Widget _region(_PullHost host, {bool enabled = true, double travel = 600}) =>
    MaterialApp(
      home: PlayerPullDownRegion(
        pullDown: host,
        enabled: enabled,
        travel: travel,
      ),
    );

void main() {
  testWidgets('taps and upward swipes never start a pull in empty space', (
    tester,
  ) async {
    final host = _PullHost();
    await tester.pumpWidget(_region(host));
    await tester.tapAt(const Offset(100, 100));
    await tester.dragFrom(const Offset(100, 200), const Offset(0, -80));
    expect(host.starts, 0);
    expect(host.updates, isEmpty);
    expect(host.ends, 0);
  });

  testWidgets('only the original finger can own a pull', (tester) async {
    final host = _PullHost();
    await tester.pumpWidget(_region(host));
    final first = await tester.startGesture(const Offset(100, 100), pointer: 1);
    final second = await tester.startGesture(
      const Offset(200, 300),
      pointer: 2,
    );

    await second.moveBy(const Offset(0, 150));
    expect(host.starts, 0);
    await first.moveBy(const Offset(0, 40));
    expect(host.starts, 1);
    expect(host.updates.last, closeTo(40 / 600, .001));
    await second.cancel();
    expect(host.cancels, 0);
    expect(host.pulling, isTrue);
    await first.moveBy(const Offset(0, 20));
    expect(host.updates.last, closeTo(60 / 600, .001));
    await first.up();
    expect(host.ends, 1);
    expect(host.cancels, 0);
  });

  testWidgets('a disabled region cancels once and ignores the old finger', (
    tester,
  ) async {
    final host = _PullHost();
    await tester.pumpWidget(_region(host));
    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(0, 40));
    expect(host.pulling, isTrue);
    await tester.pumpWidget(_region(host, enabled: false));
    expect(host.cancels, 1);
    final updates = host.updates.length;
    await gesture.moveBy(const Offset(0, 120));
    await gesture.cancel();
    expect(host.updates, hasLength(updates));
    expect(host.cancels, 1);
    expect(host.ends, 0);

    await tester.pumpWidget(_region(host));
    await tester.dragFrom(const Offset(100, 100), const Offset(0, 80));
    expect(host.starts, 2);
    expect(host.ends, 1);
  });

  testWidgets('availability is rechecked when a pending drag wins the arena', (
    tester,
  ) async {
    final host = _PullHost();
    await tester.pumpWidget(_region(host));
    final gesture = await tester.startGesture(const Offset(100, 100));
    host.available = false;
    await gesture.moveBy(const Offset(0, 80));
    await gesture.up();
    expect(host.starts, 0);
    expect(host.updates, isEmpty);
    expect(host.ends, 0);
  });

  testWidgets('replacing the host cancels the host that owns the finger', (
    tester,
  ) async {
    final oldHost = _PullHost();
    final newHost = _PullHost();
    await tester.pumpWidget(_region(oldHost));
    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pumpWidget(_region(newHost));
    expect(oldHost.cancels, 1);
    await gesture.moveBy(const Offset(0, 100));
    await gesture.up();
    expect(newHost.updates, isEmpty);
    expect(newHost.ends, 0);
    expect(oldHost.ends, 0);
  });

  testWidgets('removal, resize and backgrounding release an active pull', (
    tester,
  ) async {
    final host = _PullHost();
    await tester.pumpWidget(_region(host));
    var gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pumpWidget(_region(host, travel: 400));
    expect(host.cancels, 1);
    await gesture.up();

    gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(0, 40));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(host.cancels, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gesture.up();

    gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(host.cancels, 3);
    await gesture.cancel();
    expect(host.cancels, 3);
    expect(host.ends, 0);
  });
}
