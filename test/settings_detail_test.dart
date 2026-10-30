import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/legacy/font_settings_page.dart';
import 'package:lazer_nextgen/legacy/legacy_settings_page.dart';
import 'package:lazer_nextgen/legacy/shortcut_settings_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section.dart';
import 'package:lazer_nextgen/widgets/settings_choice.dart';

class _Navigation extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final compact in [false, true]) {
    testWidgets(
      'settings details use ${compact ? 'mobile pages' : 'desktop subviews'}',
      (tester) async {
        tester.view.physicalSize = compact
            ? const Size(390, 844)
            : const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState();
        addTearDown(state.dispose);
        final navigation = _Navigation();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            navigatorObservers: [navigation],
            home: Scaffold(body: LegacySettingsPage(state: state)),
          ),
        );
        for (final (entry, page, view) in [
          ('open-font-settings', FontSettingsPage, FontSettingsView),
          (
            'open-equalizer-settings',
            EqualizerSettingsPage,
            EqualizerSettingsView,
          ),
          (
            'open-shortcut-settings',
            ShortcutSettingsPage,
            ShortcutSettingsView,
          ),
        ]) {
          final scroll = find.byType(Scrollable).first;
          await tester.scrollUntilVisible(
            find.byKey(ValueKey(entry)),
            200,
            scrollable: scroll,
          );
          await tester.pumpAndSettle();
          final offset = tester.state<ScrollableState>(scroll).position.pixels;
          final pushed = navigation.pushes;
          await tester.tap(find.byKey(ValueKey(entry)));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 130));
          if (!compact) {
            expect(navigation.pushes, pushed);
            expect(find.byType(page), findsNothing);
            expect(
              find.byKey(const ValueKey('settings-detail-subview')),
              findsOneWidget,
            );
            final fade = find
                .ancestor(
                  of: find.byType(view),
                  matching: find.byType(FadeTransition),
                )
                .first;
            expect(
              tester.widget<FadeTransition>(fade).opacity.value,
              inExclusiveRange(.7, 1),
            );
          }
          await tester.pumpAndSettle();
          expect(find.byType(view), findsOneWidget);
          if (compact) {
            expect(navigation.pushes, pushed + 1);
            expect(find.byType(page), findsOneWidget);
            await tester.pageBack();
          } else {
            expect(find.byType(Scaffold), findsOneWidget);
            if (entry == 'open-shortcut-settings') {
              // Local history also handles platform/system back without popping the shell.
              Navigator.of(tester.element(find.byType(view))).pop();
            } else {
              await tester.tap(
                find.byKey(const ValueKey('settings-detail-back')),
              );
            }
          }
          await tester.pumpAndSettle();
          expect(find.byType(view), findsNothing);
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .pixels,
            closeTo(offset, 1),
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'desktop font editing remains live and Escape returns to settings',
    (tester) async {
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
      final card = find.byKey(const ValueKey('font-card-pageTitle'));
      await tester.drag(
        find.descendant(of: card, matching: find.byType(Slider)),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      expect(
        state.fontPreferences[FontCategory.pageTitle].scale,
        greaterThan(1),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(FontSettingsView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dynamic background controls use the shared themed controls and persist',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: AnimatedBuilder(
              animation: state,
              builder: (context, _) => LegacySettingsPage(state: state),
            ),
          ),
        ),
      );
      final mode = find.byKey(const ValueKey('player-background-mode'));
      await tester.scrollUntilVisible(mode, 200);
      expect(find.text('正在播放背景'), findsNothing);
      expect(find.text('动态背景'), findsOneWidget);
      expect(tester.widget(mode), isA<SettingsChoice<LegacyBackgroundMode>>());
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.text('静态背景').last);
      await tester.pumpAndSettle();
      expect(state.playerBackground, LegacyBackgroundMode.nowPlayingStatic);
      final follow = find.byKey(
        const ValueKey('player-background-follow-display'),
      );
      await tester.ensureVisible(follow);
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: follow, matching: find.byType(Switch)),
            )
            .onChanged,
        isNull,
      );
      final fps = find.byKey(const ValueKey('player-background-fps'));
      await tester.ensureVisible(fps);
      final slider = find.descendant(of: fps, matching: find.byType(Slider));
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      expect(
        SliderTheme.of(tester.element(slider)).disabledThumbColor,
        AppleSemanticColors.of(tester.element(slider)).tertiaryLabel,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
