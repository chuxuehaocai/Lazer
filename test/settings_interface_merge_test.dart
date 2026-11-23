// Locks the settings restructure: 外观与背景 is folded into 界面与布局, the app
// background section is named 应用背景设置, and the phone layout gets an app
// volume row (the desktop player bar already has its own).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/music_gateway.dart';

Widget _host(AppState state) => MaterialApp(
  theme: buildAppleTheme(compact: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.noScaling, disableAnimations: true),
    child: child!,
  ),
  home: Scaffold(body: AppSettingsPage(state: state, categorized: true)),
);

Future<void> _openCategory(WidgetTester tester, String label) async {
  final tile = find.ancestor(
    of: find.text(label),
    matching: find.byType(AppleListTile),
  );
  await tester.scrollUntilVisible(tile, 160);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('外观与背景 is merged into 界面与布局', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(catalog: Catalog(gateway: TestMusicGateway()));
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    expect(find.text('外观与背景'), findsNothing, reason: 'category was removed');

    await _openCategory(tester, '界面与布局');

    // Theme and language moved onto this page…
    await tester.scrollUntilVisible(find.text('主题'), 200);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);

    // …and the two background sections are distinguishable.
    await tester.scrollUntilVisible(find.text('应用背景设置'), 200);
    expect(find.text('应用背景设置'), findsOneWidget);
    expect(find.text('动态背景'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout exposes the app volume row', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(catalog: Catalog(gateway: TestMusicGateway()));
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    await _openCategory(tester, '播放与滚动');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('app-volume')),
      160,
    );
    expect(find.text('应用音量'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
