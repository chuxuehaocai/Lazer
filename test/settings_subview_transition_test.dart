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

  testWidgets('desktop detail has a page heading without an AppBar', (
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
    final title = find.byType(ApplePageTitle);
    expect(tester.widget<ApplePageTitle>(title).title, 'Detail');
    expect(
      tester
          .getBottomLeft(find.byKey(const ValueKey('settings-detail-back')))
          .dy,
      lessThanOrEqualTo(tester.getTopLeft(title).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(_detailKey)).dy,
      greaterThan(tester.getBottomLeft(title).dy),
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
