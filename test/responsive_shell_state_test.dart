import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/search_page.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';

class _ResizeState extends AppState {
  @override
  Future<SearchResults> search(String query) async => SearchResults.empty;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('phone and tablet compositions never overlap', () {
    for (final mode in AppUiMode.values) {
      for (final style in AppLayoutStyle.values) {
        for (final width in <double>[320, 600, 719, 720, 800, 1024, 1600]) {
          final compact = useCompactLayout(mode, width, layoutStyle: style);
          final tablet = useTabletLayout(mode, width, layoutStyle: style);
          expect(compact && tablet, isFalse, reason: '$mode/$style at $width');
          if (width < kCompactBreakpoint && style != AppLayoutStyle.tv) {
            expect(compact, isTrue, reason: '$mode/$style at $width');
          }
        }
      }
    }
  });

  for (final dpi in [1.0, 1.5]) {
    testWidgets('search survives responsive reparenting at $dpi DPI scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(1280 * dpi, 900 * dpi);
      addTearDown(tester.view.reset);
      final state = _ResizeState()
        ..layoutStyle = AppLayoutStyle.desktop
        ..autoDpiScale = false
        ..dpiScale = dpi;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: UiScaling(
            state: state,
            child: AppShell(state: state),
          ),
        ),
      );
      await tester.tap(
        find.byWidgetPredicate((w) => w is AppRailItem && w.label == '搜索'),
      );
      await tester.pumpAndSettle();
      final searchState = tester.state(find.byType(AppSearchPage));
      await tester.enterText(find.byType(TextField), 'keep this query');
      await tester.pumpAndSettle();
      for (final width in [719.0, 390.0, 720.0, 1280.0]) {
        tester.view.physicalSize = Size(width * dpi, 900 * dpi);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(AppSearchPage)), same(searchState));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'keep this query',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
