import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/search_page.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';

import 'support/music_gateway.dart';

class _Catalog extends Catalog {
  _Catalog() : super(gateway: TestMusicGateway());

  @override
  Future<SearchResults> search(String query) async => SearchResults(
    tracks: List.generate(
      40,
      (i) => Track(
        id: 'keyboard-$i',
        title: 'Result $i',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        coverSeed: i,
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scale in [1.0, 1.2]) {
    testWidgets(
      'shell restores full content height after the keyboard at $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState(catalog: _Catalog())
          ..autoDpiScale = false
          ..dpiScale = scale;
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            builder: (context, child) => UiScaling(state: state, child: child!),
            home: AppShell(state: state, categorizedSettings: true),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索'));
        await tester.pumpAndSettle();
        final fullHeight = tester.getRect(find.byType(AppSearchPage));
        expect(fullHeight.bottom, closeTo(844, .01));

        await tester.enterText(find.byType(TextField), 'query');
        tester.view.viewInsets = const FakeViewPadding(bottom: 340);
        await tester.pump();
        expect(
          tester.getRect(find.byType(AppSearchPage)).bottom,
          closeTo(fullHeight.bottom - 340, .01),
          reason: 'interface zoom must not enlarge the keyboard inset',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        // The keyboard's closing metrics can arrive during the page transition.
        await tester.tap(find.byTooltip('设置'));
        await tester.pump(const Duration(milliseconds: 16));
        tester.view.viewInsets = const FakeViewPadding(bottom: 170);
        await tester.pump(const Duration(milliseconds: 16));
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        final settings = find.byType(AppSettingsPage);
        expect(
          tester.getRect(settings).bottom,
          closeTo(fullHeight.bottom, .01),
        );
        final list = find.descendant(
          of: settings,
          matching: find.byType(ListView),
        );
        expect(tester.getRect(list).bottom, closeTo(fullHeight.bottom, .01));
        await tester.drag(list, const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(find.text('关于 Lazer'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
