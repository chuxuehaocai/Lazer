import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/animation/apple_spring.dart';
import 'package:lazer_nextgen/player/player_backdrop.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/font_settings_page.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> pumpSettings(
    WidgetTester tester, {
    Size size = const Size(1280, 3000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()..uiMode = AppUiMode.desktop;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(body: AppSettingsPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('settings values refresh after a slider click', (tester) async {
    final state = await pumpSettings(tester);
    final row = find.byKey(const ValueKey('animation-speed-slider'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    final slider = find.descendant(of: row, matching: find.byType(Slider));
    await tester.tapAt(tester.getTopLeft(slider) + const Offset(8, 20));
    await tester.pumpAndSettle();
    expect(state.animationSpeed, MotionTiming.minSpeed);
    expect(
      find.descendant(
        of: row,
        matching: find.text('${MotionTiming.minSpeed.toStringAsFixed(1)}×'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('settings values refresh after the reset button', (tester) async {
    final state = await pumpSettings(tester);
    await state.setAnimationSpeed(MotionTiming.maxSpeed);
    await tester.pumpAndSettle();
    final reset = find.byKey(const ValueKey('animation-speed-reset'));
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(state.animationSpeed, MotionTiming.defaultSpeed);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('animation-speed-slider')),
        matching: find.text('1.0×'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('settings values refresh after a dropdown choice', (
    tester,
  ) async {
    final state = await pumpSettings(tester);
    final choice = find.byKey(const ValueKey('browse-background-mode'));
    await tester.ensureVisible(choice);
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    await tester.tap(find.text('静态背景').last);
    await tester.pumpAndSettle();
    expect(state.backgroundMode, AppBackgroundMode.nowPlayingStatic);
    expect(
      find.descendant(of: choice, matching: find.text('静态背景')),
      findsOneWidget,
    );
  });

  testWidgets('top-bar blur and opacity are adjustable in interface layout', (
    tester,
  ) async {
    final state = await pumpSettings(tester);
    final blur = find.byKey(const ValueKey('header-blur-slider'));
    await tester.ensureVisible(blur);
    await tester.pumpAndSettle();
    await tester.drag(
      find.descendant(of: blur, matching: find.byType(Slider)),
      const Offset(400, 0),
    );
    await tester.pumpAndSettle();
    expect(state.headerBlur, kHeaderBlurMax);
    expect(
      find.descendant(
        of: blur,
        matching: find.text('${kHeaderBlurMax.round()} px'),
      ),
      findsOneWidget,
    );

    final opacity = find.byKey(const ValueKey('header-opacity-slider'));
    await tester.ensureVisible(opacity);
    await tester.pumpAndSettle();
    await tester.drag(
      find.descendant(of: opacity, matching: find.byType(Slider)),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();
    expect(state.headerOpacity, closeTo(kHeaderOpacityMin, .001));
  });

  testWidgets('the background dark edge is a persisted switch', (tester) async {
    final state = await pumpSettings(tester);
    await state.setAppBackground(AppBackgroundMode.nowPlayingDynamic);
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('background-dark-edge'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
            find.descendant(of: row, matching: find.byType(Switch)),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(state.backgroundDarkEdgeEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lazer_background_dark_edge'), isFalse);
  });

  testWidgets('the dark edge gradient is omitted when disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AlbumBlurFlow(
            track: null,
            mode: AppBackgroundMode.nowPlayingDynamic,
            pageColor: Colors.transparent,
            darkEdge: false,
          ),
        ),
      ),
    );
    await tester.pump();
    final radial = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).gradient is RadialGradient,
    );
    expect(radial, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the font page header names the page', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => FontSettingsView(state: state),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('字体自定义'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
