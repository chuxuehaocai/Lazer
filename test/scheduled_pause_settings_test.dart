import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/legacy/legacy_settings_page.dart';
import 'package:lazer_nextgen/legacy/scheduled_pause_settings.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/scheduled_pause.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('editor validates, saves multiple ranges, edits and deletes', (
    tester,
  ) async {
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
    await tester.tap(find.byKey(const ValueKey('add-pause-window')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pause-window-start')),
      '23:30',
    );
    await tester.enterText(
      find.byKey(const ValueKey('pause-window-end')),
      '23:30',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-window')));
    await tester.pump();
    expect(find.text('开始时间和结束时间不能相同'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('pause-window-end')),
      '25:00',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-window')));
    await tester.pump();
    expect(find.text('请输入有效的24小时制时间，例如23:30'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('pause-window-end')),
      '07:00',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-window')));
    await tester.pumpAndSettle();
    final first = state.scheduledPause.windows.single;
    expect(first.startMinute, 23 * 60 + 30);
    expect(first.endMinute, 7 * 60);
    await tester.tap(find.byKey(const ValueKey('add-pause-window')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pause-window-start')),
      '12:00',
    );
    await tester.enterText(
      find.byKey(const ValueKey('pause-window-end')),
      '13:00',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-window')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.windows, hasLength(2));
    await tester.tap(find.byKey(ValueKey('pause-window-enabled-${first.id}')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.windows.first.enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('scheduled-pause-enabled')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.enabled, isTrue);
    await tester.tap(find.text('12:00 - 13:00'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('pause-window-end')),
      '14:00',
    );
    await tester.tap(find.byKey(const ValueKey('save-pause-window')));
    await tester.pumpAndSettle();
    expect(state.scheduledPause.windows.last.endMinute, 14 * 60);
    await tester.tap(find.byKey(ValueKey('pause-window-delete-${first.id}')));
    await tester.pumpAndSettle();
    final saved = (await SharedPreferences.getInstance()).getString(
      AppState.scheduledPauseKey,
    );
    final restored = ScheduledPauseSettings.decode(saved);
    expect(restored.enabled, isTrue);
    expect(restored.windows.single.endMinute, 14 * 60);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

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
            home: Scaffold(body: LegacySettingsPage(state: state)),
          ),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('open-scheduled-pause')),
          300,
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
