import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/player/now_playing_route.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const _bodyKey = ValueKey('motion-route-body');
const _body = SizedBox.expand(
  key: _bodyKey,
  child: ColoredBox(color: Colors.teal),
);

class _PlayerRoute extends NowPlayingRoute {
  _PlayerRoute(AppState state, {this.child = _body}) : super(state: state);
  final Widget child;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => child;
}

class _TrackedAnimation extends AlwaysStoppedAnimation<double> {
  _TrackedAnimation() : super(1);
  final statuses = <AnimationStatusListener>{};
  final listeners = <VoidCallback>{};
  @override
  void addStatusListener(AnimationStatusListener listener) =>
      statuses.add(listener);
  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      statuses.remove(listener);
  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
}

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  bool reduced = false,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: LazerPageTransitionsBuilder(),
            TargetPlatform.windows: LazerPageTransitionsBuilder(),
          },
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: const SizedBox.expand(),
    ),
  );
  return navigator;
}

double _pageProgress(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(_bodyKey),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

double _playerOffset(WidgetTester tester, {Key key = _bodyKey}) => tester
    .widget<FractionalTranslation>(
      find
          .ancestor(
            of: find.byKey(key),
            matching: find.byType(FractionalTranslation),
          )
          .first,
    )
    .translation
    .dy;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('ordinary routes leave fast and decelerate on pop', (
    tester,
  ) async {
    final navigator = await _host(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _body),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(_pageProgress(tester), 1);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    final early = _pageProgress(tester);
    expect(
      early,
      lessThan(.5),
      reason: 'The pop must cover most of its travel early.',
    );
    await tester.pump(const Duration(milliseconds: 75));
    final later = _pageProgress(tester);
    expect(early - later, lessThan((1 - early) / 2));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(_bodyKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'popping an unfinished ordinary push preserves its visible position',
    (tester) async {
      final navigator = await _host(tester);
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => _body),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final before = _pageProgress(tester);
      navigator.currentState!.pop();
      await tester.pump();
      expect(_pageProgress(tester), closeTo(before, .00001));
      await tester.pump(const Duration(milliseconds: 20));
      expect(_pageProgress(tester), lessThan(before / 2));
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.byKey(_bodyKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('route rebuilds release every transition listener', (
    tester,
  ) async {
    final animation = _TrackedAnimation();
    final route = MaterialPageRoute<void>(builder: (_) => _body);
    var listenerCount = 0;
    var statusCount = 0;
    for (var rebuild = 0; rebuild < 10; rebuild++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) =>
                const LazerPageTransitionsBuilder().buildTransitions<void>(
                  route,
                  context,
                  animation,
                  kAlwaysDismissedAnimation,
                  Text('body $rebuild'),
                ),
          ),
        ),
      );
      if (rebuild == 0) {
        listenerCount = animation.listeners.length;
        statusCount = animation.statuses.length;
      }
      expect(animation.listeners, hasLength(listenerCount));
      expect(animation.statuses, hasLength(statusCount));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(animation.listeners, isEmpty);
    expect(animation.statuses, isEmpty);
    route.dispose();
  });

  testWidgets(
    'a fully open player leaves fast and slows into the bottom edge',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      final navigator = await _host(tester);
      navigator.currentState!.push(_PlayerRoute(state));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      expect(_playerOffset(tester), 0);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final early = _playerOffset(tester);
      expect(early, greaterThan(.5));
      await tester.pump(const Duration(milliseconds: 75));
      expect(_playerOffset(tester) - early, lessThan(early / 2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(_bodyKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a player can reopen while its previous route is still leaving', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final navigator = await _host(tester);
    navigator.currentState!.push(_PlayerRoute(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    const nextKey = ValueKey('next-player');
    final nextRoute = _PlayerRoute(
      state,
      child: const SizedBox.expand(key: nextKey),
    );
    navigator.currentState!.push(nextRoute);
    await tester.pump();
    await tester.pump();
    expect(_playerOffset(tester, key: nextKey), 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_playerOffset(tester, key: nextKey), lessThan(.5));
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byKey(_bodyKey, skipOffstage: false), findsNothing);
    expect(_playerOffset(tester, key: nextKey), 0);
    expect(nextRoute.canStart, isTrue);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.byKey(nextKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'player pop starts fast and can reverse an unfinished push without a jump',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      final navigator = await _host(tester);
      navigator.currentState!.push(_PlayerRoute(state));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final before = _playerOffset(tester);
      navigator.currentState!.pop();
      await tester.pump();
      expect(_playerOffset(tester), closeTo(before, .00001));
      await tester.pump(const Duration(milliseconds: 60));
      expect(_playerOffset(tester), greaterThan(before + (1 - before) / 2));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(_bodyKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final pulled in [.1, .4]) {
    testWidgets(
      'player release at $pulled continues from the finger without a jump',
      (tester) async {
        final state = AppState();
        addTearDown(state.dispose);
        final navigator = await _host(tester);
        final route = _PlayerRoute(state);
        navigator.currentState!.push(route);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 320));
        expect(route.canStart, isTrue);
        route.startPull();
        route.updatePull(pulled);
        await tester.pump();
        expect(_playerOffset(tester), closeTo(pulled, .00001));
        route.endPull(0);
        await tester.pump();
        expect(_playerOffset(tester), closeTo(pulled, .00001));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          _playerOffset(tester),
          pulled < .22 ? lessThan(pulled) : greaterThan(pulled),
        );
        await tester.pump(const Duration(milliseconds: 400));
        if (pulled < .22) {
          expect(_playerOffset(tester), 0);
          expect(route.canStart, isTrue);
          navigator.currentState!.pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(find.byKey(_bodyKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reduced motion skips ordinary and player route transforms', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final navigator = await _host(tester, reduced: true);
    for (final route in <PageRoute<void>>[
      MaterialPageRoute<void>(builder: (_) => _body),
      _PlayerRoute(state),
    ]) {
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_bodyKey), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(_bodyKey),
          matching: find.byType(SlideTransition),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byKey(_bodyKey),
          matching: find.byType(FractionalTranslation),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 400));
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'platform reduced motion also finishes the player route promptly',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      final state = AppState();
      addTearDown(state.dispose);
      final navigator = await _host(tester, reduced: true);
      final route = _PlayerRoute(state);
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(route.animation!.status, AnimationStatus.completed);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byKey(_bodyKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
