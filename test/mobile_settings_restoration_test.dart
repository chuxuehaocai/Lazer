import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/music_gateway.dart';

Widget _host(AppState state, {required bool compact, double textScale = 1}) =>
    MaterialApp(
      theme: buildAppleTheme(compact: compact),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 24),
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(body: AppSettingsPage(state: state, categorized: true)),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('phone settings restore heading and navigate below safe area', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog(gateway: TestMusicGateway()));
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, compact: true));
    await tester.pumpAndSettle();
    expect(find.text('按分类整理常用选项，减少滚动和查找。'), findsOneWidget);
    final category = find.ancestor(
      of: find.text('界面与布局'),
      matching: find.byType(AppleListTile),
    );
    expect(tester.getSize(category).height, 76);
    await tester.tap(category);
    await tester.pumpAndSettle();
    final back = find.byKey(const ValueKey('settings-detail-back'));
    expect(tester.getTopLeft(back).dy, 32);
    expect(find.text('布局样式'), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('按分类整理常用选项，减少滚动和查找。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(state, compact: true, textScale: 2.4));
    await tester.pumpAndSettle();
    expect(tester.getSize(category).height, greaterThan(76));
    expect(tester.takeException(), isNull);
  });

  testWidgets('forced phone settings keep mobile measure on a desktop window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog(gateway: TestMusicGateway()));
    addTearDown(state.dispose);
    for (final compact in [true, false]) {
      state.layoutStyle = compact
          ? AppLayoutStyle.phone
          : AppLayoutStyle.desktop;
      await tester.pumpWidget(_host(state, compact: compact));
      await tester.pumpAndSettle();
      expect(
        find.text('按分类整理常用选项，减少滚动和查找。'),
        compact ? findsOneWidget : findsNothing,
      );
      expect(tester.getSize(find.byType(ListView)).width, compact ? 760 : 980);
      final category = find.ancestor(
        of: find.text('界面与布局'),
        matching: find.byType(AppleListTile),
      );
      expect(tester.getSize(category).height, compact ? 88 : 96);
      expect(tester.takeException(), isNull);
    }
  });
}
