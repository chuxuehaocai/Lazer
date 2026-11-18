import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/adaptive_app_theme.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    testWidgets('phone palette follows scaled layout in $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final state = AppState()
        ..autoDpiScale = false
        ..dpiScale = 1.5
        ..layoutStyle = AppLayoutStyle.desktop;
      addTearDown(state.dispose);
      ThemeData? resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(brightness: brightness),
          builder: (context, child) => UiScaling(
            state: state,
            child: AdaptiveAppTheme(state: state, child: child!),
          ),
          home: Builder(
            builder: (context) {
              resolved = Theme.of(context);
              return const Scaffold(body: TextField());
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'keep edit');
      final fieldState = tester.state(find.byType(TextField));
      final desktopPrimary = resolved!.colorScheme.primary;
      expect(desktopPrimary, isNot(AppleColors.musicRed));
      for (final width in [719.0, 390.0, 720.0, 1280.0]) {
        tester.view.physicalSize = Size(width * 1.5, 900);
        await tester.pumpAndSettle();
        expect(
          resolved!.colorScheme.primary,
          width < 720 ? AppleColors.musicRed : desktopPrimary,
        );
        expect(tester.state(find.byType(TextField)), same(fieldState));
        expect(find.text('keep edit'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('explicit phone style preserves a custom accent and fonts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()
      ..autoDpiScale = false
      ..layoutStyle = AppLayoutStyle.phone
      ..paletteMode = AppPaletteMode.custom
      ..accentColor = const Color(0xFF006B3C);
    addTearDown(state.dispose);
    ThemeData? resolved;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: UiScaling(
          state: state,
          child: AdaptiveAppTheme(
            state: state,
            child: Builder(
              builder: (context) {
                resolved = Theme.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    final expected = buildAppleTheme(
      compact: true,
      seedAccent: state.accentSeed,
    );
    expect(resolved!.colorScheme, expected.colorScheme);
    expect(
      resolved!.textTheme.bodyLarge!.fontFamily,
      expected.textTheme.bodyLarge!.fontFamily,
    );
    expect(
      resolved!.textTheme.bodyLarge!.fontSize,
      expected.textTheme.bodyLarge!.fontSize,
    );
    expect(state.paletteMode, AppPaletteMode.custom);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
