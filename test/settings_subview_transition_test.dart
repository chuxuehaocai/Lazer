import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:lazer_nextgen/widgets/settings_detail.dart';

const _overviewKey = ValueKey('retained-settings-overview');
const _openKey = ValueKey('open-test-settings-detail');
const _detailKey = ValueKey('test-settings-detail');

Widget _host({bool reducedMotion = false}) => MaterialApp(
  theme: buildAppleTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
    child: child!,
  ),
  home: Scaffold(
    body: SettingsDetailHost(
      compact: false,
      child: Builder(
        builder: (context) => ListView(
          key: _overviewKey,
          children: [
            TextButton(
              key: _openKey,
              onPressed: () => SettingsDetailHost.open(
                context,
                page: (_) => throw StateError('Desktop must not push a page'),
                view: (_) => SettingsDetailScaffold(
                  title: 'Detail',
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('Reset')),
                  ],
                  child: const SizedBox.expand(key: _detailKey),
                ),
              ),
              child: const Text('Open'),
            ),
            const SizedBox(height: 1400),
          ],
        ),
      ),
    ),
  ),
);

Future<void> _backEvent(
  WidgetTester tester,
  String method, [
  double? progress,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(
        method,
        progress == null
            ? null
            : {
                'touchOffset': <double>[5, 200],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (_) {},
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'embedded detail previews Android back, cancels, then commits once',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.tap(find.byKey(_openKey));
      await tester.pumpAndSettle();
      final element = tester.element(find.byKey(_detailKey));
      await _backEvent(tester, 'startBackGesture', 0);
      await _backEvent(tester, 'updateBackGestureProgress', .6);
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(_detailKey),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await _backEvent(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(tester.element(find.byKey(_detailKey)), same(element));
      await _backEvent(tester, 'startBackGesture', 0);
      await _backEvent(tester, 'updateBackGestureProgress', .7);
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.byKey(_detailKey), findsNothing);
      expect(find.byKey(_overviewKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('embedded detail accepts an iOS leading-edge return gesture', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(_detailKey));
    final gesture = await tester.startGesture(Offset(2, rect.center.dy));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(rect.width * .7, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(_detailKey), findsNothing);
    expect(find.byKey(_overviewKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('overview and detail never paint over one another', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final overview = find.byKey(_overviewKey, skipOffstage: false);
    final element = tester.element(overview);
    double opacity(Finder child) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: child,
                matching: find.byType(FadeTransition, skipOffstage: false),
              )
              .first,
        )
        .opacity
        .value;
    Future<void> checkFrames() async {
      for (var frame = 0; frame < 45; frame++) {
        final detail = find.byKey(_detailKey, skipOffstage: false);
        if (detail.evaluate().isNotEmpty) {
          expect(
            opacity(overview) * opacity(detail),
            0,
            reason: 'settings pages must not cross-fade their controls',
          );
        }
        expect(tester.element(overview), same(element));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await tester.tap(find.byKey(_openKey));
    await tester.pump();
    await checkFrames();
    await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
    await tester.pump();
    await checkFrames();
    expect(find.byKey(_detailKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop detail keeps controls without an extra page heading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host());
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(ApplePageTitle), findsNothing);
    expect(find.text('Detail'), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(_detailKey)).dy -
          tester
              .getBottomLeft(find.byKey(const ValueKey('settings-detail-back')))
              .dy,
      inInclusiveRange(0, 16),
    );
    expect(find.text('Reset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('return never replaces the departing subview with a Scaffold', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final overview = find.byKey(_overviewKey, skipOffstage: false);
    final element = tester.element(overview);
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: overview, matching: find.byType(Scrollable)),
    );
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(identical(tester.element(overview), element), isTrue);
    scroll.position.jumpTo(180);
    await tester.pump();
    final detailElement = tester.element(find.byKey(_detailKey));
    await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
    await tester.pump();
    for (var frame = 0; frame < 16; frame++) {
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(identical(tester.element(overview), element), isTrue);
      expect(
        identical(tester.element(find.byKey(_detailKey)), detailElement),
        isTrue,
      );
      expect(scroll.position.pixels, 180);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(_detailKey), findsNothing);
    expect(scroll.position.pixels, 180);
  });

  testWidgets('an interrupted entrance reverses without remounting the pages', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final overview = tester.element(find.byKey(_overviewKey));
    for (var cycle = 0; cycle < 3; cycle++) {
      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      Navigator.of(tester.element(find.byKey(_detailKey))).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(_detailKey), findsNothing);
      expect(tester.element(find.byKey(_overviewKey)), same(overview));
      expect(find.byType(Scaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'a subview opened from another subview animates and returns one level',
    (tester) async {
      const managerKey = ValueKey('test-settings-manager');
      const nestedKey = ValueKey('test-settings-nested');

      Widget shell(BuildContext context) => ListView(
        key: _overviewKey,
        children: [
          TextButton(
            key: _openKey,
            onPressed: () => SettingsDetailHost.open(
              context,
              page: (_) => throw StateError('Desktop must not push a page'),
              view: (viewContext) => SettingsDetailScaffold(
                title: 'Manager',
                child: Builder(
                  builder: (inner) => Align(
                    alignment: Alignment.topLeft,
                    child: TextButton(
                      key: managerKey,
                      onPressed: () => SettingsDetailHost.open(
                        inner,
                        page: (_) =>
                            throw StateError('Desktop must not push a page'),
                        view: (_) => SettingsDetailScaffold(
                          title: 'Market',
                          child: const SizedBox.expand(key: nestedKey),
                        ),
                      ),
                      child: const Text('Market'),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
          const SizedBox(height: 1400),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: SettingsDetailHost(
              compact: false,
              child: Builder(builder: shell),
            ),
          ),
        ),
      );

      // Level one: the manager, reached straight from the overview.
      await tester.tap(find.byKey(_openKey));
      await tester.pumpAndSettle();
      final Element manager = tester.element(find.byKey(managerKey));

      // Level two: the market is pushed on top and must travel in, not appear.
      double opacityOf(Finder finder) => tester
          .widget<Opacity>(
            // Outermost of its kind: the nested stack wrapper, not the
            // FadeTransition inside the page being animated.
            find.ancestor(of: finder, matching: find.byType(Opacity)).last,
          )
          .opacity;

      /// Every fractional offset applied above [finder]; the stack wrapper is
      /// one of them, and a `SlideTransition` inside the page is another.
      List<double> slidesOf(Finder finder) => find
          .ancestor(of: finder, matching: find.byType(FractionalTranslation))
          .evaluate()
          .map(
            (Element e) => (e.widget as FractionalTranslation).translation.dx,
          )
          .toList();

      await tester.tap(find.byKey(managerKey));
      await tester.pump();
      expect(find.byKey(nestedKey), findsOneWidget);
      expect(
        identical(tester.element(find.byKey(managerKey)), manager),
        isTrue,
        reason: 'the subview underneath stays mounted while the new one enters',
      );
      // The subview underneath leaves first and the new one fades in behind
      // it: at no point do both sets of controls paint at full strength.
      final List<double> leaving = <double>[];
      final List<double> arriving = <double>[];
      bool slidIn = false;
      bool slidOut = false;
      for (var frame = 0; frame < 18; frame++) {
        if (find.byKey(managerKey).evaluate().isNotEmpty) {
          leaving.add(opacityOf(find.byKey(managerKey)));
          slidOut =
              slidOut ||
              slidesOf(find.byKey(managerKey)).any((double dx) => dx < -.001);
        }
        if (find.byKey(nestedKey).evaluate().isNotEmpty) {
          arriving.add(opacityOf(find.byKey(nestedKey)));
          slidIn =
              slidIn ||
              slidesOf(find.byKey(nestedKey)).any((double dx) => dx > .001);
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        leaving.any((double value) => value > 0 && value < 1),
        isTrue,
        reason: 'the subview underneath fades out instead of vanishing',
      );
      expect(
        arriving.any((double value) => value > 0 && value < 1),
        isTrue,
        reason: 'the new subview fades in',
      );
      expect(
        slidIn,
        isTrue,
        reason: 'the new subview slides in from the right',
      );
      expect(slidOut, isTrue, reason: 'the old subview slides out to the left');

      await tester.pumpAndSettle();
      expect(find.byKey(nestedKey), findsOneWidget);
      // The page underneath is retained (its scroll and fields survive), but it
      // no longer takes taps while the new one covers it.
      expect(find.byKey(managerKey).hitTestable(), findsNothing);

      // Back inside the stack: the market leaves the way it came, and the
      // manager returns without remounting.
      await tester.tap(
        find.byKey(const ValueKey('settings-detail-back')).hitTestable(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byKey(nestedKey), findsOneWidget);
      expect(find.byKey(managerKey), findsOneWidget);
      expect(
        identical(tester.element(find.byKey(managerKey)), manager),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(nestedKey), findsNothing);
      expect(find.byKey(managerKey), findsOneWidget);

      // The last level still closes the whole subview back to the overview.
      await tester.tap(
        find.byKey(const ValueKey('settings-detail-back')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(managerKey), findsNothing);
      expect(find.byKey(_overviewKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reduced motion removes the detail immediately on return', (
    tester,
  ) async {
    await tester.pumpWidget(_host(reducedMotion: true));
    await tester.tap(find.byKey(_openKey));
    await tester.pump();
    expect(find.byKey(_detailKey), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
    await tester.pump();
    expect(find.byKey(_detailKey), findsNothing);
    expect(find.byKey(_overviewKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
