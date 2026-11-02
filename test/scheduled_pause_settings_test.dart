import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';
import 'package:lazer_nextgen/ui/scheduled_pause_settings.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/scheduled_pause.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('editor validates and saves daily pause points', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: ScheduledPauseSettingsPage(state: state),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('add-pause-point')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pause-point-time')),
      '25:00',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-point')));
    await tester.pump();
    expect(find.text('请输入有效的24小时制时间，例如23:30'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('pause-point-time')),
      '23:30',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-point')));
    await tester.pumpAndSettle();
    final first = state.scheduledPause.points.single;
    expect(first.minute, 23 * 60 + 30);
    expect(find.text('23:30'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-pause-point')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pause-point-time')),
      '12:00',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-point')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.points, hasLength(2));
    await tester.tap(find.byKey(ValueKey('pause-point-enabled-${first.id}')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.points.first.enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('scheduled-pause-enabled')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.enabled, isTrue);
    await tester.tap(find.text('12:00'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pause-point-time')),
      '14:00',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-point')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.points.last.minute, 14 * 60);
    await tester.tap(find.byKey(ValueKey('pause-point-delete-${first.id}')));
    await tester.pumpAndSettle();
    final saved = (await SharedPreferences.getInstance()).getString(
      AppState.scheduledPauseKey,
    );
    final restored = ScheduledPauseSettings.decode(saved);
    expect(restored.enabled, isTrue);
    expect(restored.points.single.minute, 14 * 60);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  for (final (locale, addLabel, emptyLabel, timeLabel) in [
    (
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      '添加暂停时间点',
      '还没有暂停时间点',
      '暂停时间',
    ),
    (
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      '新增暫停時間點',
      '尚無暫停時間點',
      '暫停時間',
    ),
    (const Locale('en'), 'Add pause time', 'No pause times yet', 'Pause time'),
    (const Locale('ja'), '一時停止する時刻を追加', '一時停止する時刻はまだありません', '一時停止する時刻'),
  ]) {
    testWidgets('daily point editor translates ${locale.toLanguageTag()}', (
      tester,
    ) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.runAsync(() => AppLocalizations.delegate.load(locale));
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          theme: buildAppleTheme(),
          home: ScheduledPauseSettingsPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(addLabel),
        findsOneWidget,
        reason: tester.widgetList<Text>(find.byType(Text))
            .map((text) => text.data).join(' | '),
      );
      expect(find.text(emptyLabel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-pause-point')));
      await tester.pumpAndSettle();
      expect(find.text(timeLabel), findsOneWidget);
      expect(find.byKey(const ValueKey('pause-point-time')), findsOneWidget);
      expect(find.text('开始时间'), findsNothing);
      expect(find.text('结束时间'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final mobile in [true, false]) {
    testWidgets(
      'settings opens scheduled pause in ${mobile ? 'mobile page' : 'desktop subview'}',
      (tester) async {
        tester.view.physicalSize = Size(mobile ? 390 : 1280, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState()
          ..uiMode = mobile ? AppUiMode.mobile : AppUiMode.desktop;
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            home: Scaffold(body: AppSettingsPage(state: state)),
          ),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('open-scheduled-pause')),
          300,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('open-scheduled-pause')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('open-scheduled-pause')));
        await tester.pumpAndSettle();
        expect(find.byType(ScheduledPauseSettingsPage), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-detail-subview')),
          mobile ? findsNothing : findsOneWidget,
        );
        if (mobile) {
          await tester.pageBack();
        } else {
          await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
        }
        await tester.pumpAndSettle();
        expect(find.byType(ScheduledPauseSettingsPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
