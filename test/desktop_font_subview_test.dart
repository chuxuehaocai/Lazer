import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/legacy/legacy_settings_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('desktop font controls use two editable columns', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()..uiMode = AppUiMode.desktop;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(body: LegacySettingsPage(state: state)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-font-settings')));
    await tester.pumpAndSettle();

    final first = find.byKey(const ValueKey('font-card-pageTitle'));
    final second = find.byKey(const ValueKey('font-card-title'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(tester.getRect(first).right, lessThan(tester.getRect(second).left));
    await tester.drag(
      find.descendant(of: second, matching: find.byType(Slider)),
      const Offset(45, 0),
    );
    await tester.pumpAndSettle();
    expect(state.fontPreferences[FontCategory.title].scale, greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('large desktop text reflows and mobile stays single column', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final desktop in [true, false]) {
      tester.view.physicalSize = desktop
          ? const Size(1280, 800)
          : const Size(390, 844);
      final state = AppState()
        ..uiMode = desktop ? AppUiMode.desktop : AppUiMode.mobile
        ..fontPreferences = const FontPreferences({
          FontCategory.pageTitle: FontCustomization(scale: 1.6),
          FontCategory.body: FontCustomization(scale: 1.6),
          FontCategory.controls: FontCustomization(scale: 1.6),
        });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(fonts: state.fontPreferences),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(body: LegacySettingsPage(state: state)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-font-settings')));
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('font-card-pageTitle'));
      final second = find.byKey(const ValueKey('font-card-title'));
      if (desktop) {
        expect(
          tester.getRect(first).right,
          lessThan(tester.getRect(second).left),
        );
      } else {
        expect(
          tester.getRect(first).bottom,
          lessThanOrEqualTo(tester.getRect(second).top),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    }
  });
}
