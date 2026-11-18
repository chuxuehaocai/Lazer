import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/navigation/pull_down_to_close.dart';
import 'package:lazer_nextgen/player/now_playing_route.dart';
import 'package:lazer_nextgen/state/app_state.dart';

class _PlayerRoute extends NowPlayingRoute {
  _PlayerRoute({required super.state});

  bool disposed = false;
  double get openness => controller!.value;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => ColoredBox(
    key: const ValueKey('player'),
    color: Colors.blue,
    child: PlayerPullDownRegion(
      pullDown: this,
      travel: MediaQuery.sizeOf(context).height,
    ),
  );

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

Future<(_PlayerRoute, NavigatorState)> _mount(WidgetTester tester) async {
  final state = AppState();
  addTearDown(state.dispose);
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: key,
      home: const ColoredBox(color: Colors.white),
    ),
  );
  final route = _PlayerRoute(state: state);
  key.currentState!.push(route);
  await tester.pumpAndSettle();
  expect(route.canStart, isTrue);
  return (route, key.currentState!);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('late pull events cannot resurrect a player being popped', (
    tester,
  ) async {
    final (route, nav) = await _mount(tester);
    final finger = await tester.startGesture(const Offset(100, 100));
    await finger.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(route.openness, lessThan(1));

    nav.pop();
    await finger.moveBy(const Offset(0, 30));
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(route.disposed, isTrue);
    expect(nav.canPop(), isFalse);
    expect(find.byKey(const ValueKey('player')), findsNothing);

    // A host can also have queued terminal callbacks after route disposal.
    route.startPull();
    route.updatePull(.5);
    route.endPull(1000);
    route.cancelPull();
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening another route cancels the pull without popping it', (
    tester,
  ) async {
    final (route, nav) = await _mount(tester);
    route.startPull();
    route.updatePull(.3);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const ColoredBox(key: ValueKey('sheet'), color: Colors.red),
      ),
    );
    route.endPull(2000);
    route.cancelPull();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet')), findsOneWidget);
    expect(route.openness, closeTo(1, .001));
    nav.pop();
    await tester.pumpAndSettle();
    expect(route.canStart, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid cancel and regrab can still finish a dismissal', (
    tester,
  ) async {
    final (route, nav) = await _mount(tester);
    for (var i = 0; i < 8; i++) {
      route.startPull();
      route.updatePull(.1);
      route.cancelPull();
      route.endPull(2000); // Duplicate terminal events are ignored.
      await tester.pump(const Duration(milliseconds: 32));
      expect(route.isCurrent, isTrue);
    }
    route.startPull();
    route.updatePull(.35);
    route.endPull(0);
    route.cancelPull();
    await tester.pumpAndSettle();
    expect(route.disposed, isTrue);
    expect(nav.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate predictive back events do not strand navigation', (
    tester,
  ) async {
    final (route, nav) = await _mount(tester);
    route.handleStartBackGesture(progress: .85);
    route.handleStartBackGesture(progress: .6);
    expect(nav.userGestureInProgress, isTrue);
    expect(route.canStart, isFalse);
    route.handleCancelBackGesture();
    route.handleUpdateBackGestureProgress(progress: .2);
    route.handleCancelBackGesture();
    route.handleCommitBackGesture();
    await tester.pumpAndSettle();
    expect(nav.userGestureInProgress, isFalse);
    expect(route.openness, closeTo(1, .001));
    expect(route.canStart, isTrue);

    route.handleStartBackGesture(progress: .5);
    route.handleCommitBackGesture();
    route.handleCancelBackGesture();
    route.handleUpdateBackGestureProgress(progress: .8);
    await tester.pumpAndSettle();
    expect(route.disposed, isTrue);
    expect(nav.userGestureInProgress, isFalse);
    expect(nav.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'backgrounding cancels predictive back without a terminal event',
    (tester) async {
      final (route, nav) = await _mount(tester);
      route.handleStartBackGesture(progress: .6);
      expect(nav.userGestureInProgress, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(nav.userGestureInProgress, isFalse);
      expect(route.openness, closeTo(1, .001));
      expect(route.canStart, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
