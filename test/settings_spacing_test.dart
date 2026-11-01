import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/legacy/legacy_settings_page.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/tv/lan_remote.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:lazer_nextgen/widgets/settings_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder _cardAround(Finder child) =>
    find.ancestor(of: child, matching: find.byType(AppleGroupedCard)).first;

Rect _cardRect(WidgetTester tester, Finder child) => tester.getRect(
  find
      .descendant(of: _cardAround(child), matching: find.byType(DecoratedBox))
      .first,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final double width in <double>[320, 1280]) {
    testWidgets('settings cards have consistent gutters at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 12000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState();
      final remote = LanRemoteController(state);
      addTearDown(() {
        remote.dispose();
        state.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(),
          home: LanRemoteScope(
            controller: remote,
            child: Scaffold(body: LegacySettingsPage(state: state)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Rect cache = _cardRect(
        tester,
        find.byKey(const ValueKey('playback-cache-mode')),
      );
      final Rect download = _cardRect(
        tester,
        find.byKey(const ValueKey('download-quality')),
      );
      final Rect engine = _cardRect(
        tester,
        find.byKey(const ValueKey('audio-engine-choice')),
      );
      final Rect equalizer = _cardRect(
        tester,
        find.byKey(const ValueKey('open-equalizer-settings')),
      );
      expect(download.top - cache.bottom, closeTo(16, .01));
      expect(equalizer.top - engine.bottom, closeTo(16, .01));

      // Plain settings, the cache controls and the LAN remote must have the
      // same breathing room even though their controls have different sizes.
      for (final String label in <String>[
        '配色',
        '动画帧预算',
        '边听边缓存',
        '缓存歌曲上限',
        '局域网遥控器',
      ]) {
        final Finder row = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((widget) => widget is SettingsRow),
        );
        expect(row, findsOneWidget);
        expect(tester.getSize(row).height, greaterThanOrEqualTo(72));
        final Rect rowRect = tester.getRect(row);
        final Rect labelRect = tester.getRect(find.text(label));
        expect(labelRect.top - rowRect.top, greaterThanOrEqualTo(12));
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('局域网遥控器'));
      await tester.pumpAndSettle();
      expect(remote.enabled, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow inset settings keep controls visible and focusable', (
    tester,
  ) async {
    final FocusNode modeFocus = FocusNode();
    final FocusNode switchFocus = FocusNode();
    addTearDown(modeFocus.dispose);
    addTearDown(switchFocus.dispose);
    bool enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: TvScope(
          active: true,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: StatefulBuilder(
                  builder: (context, setState) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SettingsRow(
                        label: '缓存策略',
                        subtitle: '在宽窗口中的窄设置面板也能完整操作',
                        trailing: DropdownButton<int>(
                          focusNode: modeFocus,
                          value: 1,
                          items: const <DropdownMenuItem<int>>[
                            DropdownMenuItem(value: 1, child: Text('智能缓存')),
                          ],
                          onChanged: (_) {},
                        ),
                      ),
                      SettingsRow(
                        label: '局域网遥控器',
                        subtitle: '同一网络的手机或电脑可以输入文字',
                        trailing: Switch(
                          focusNode: switchFocus,
                          value: enabled,
                          onChanged: (value) => setState(() => enabled = value),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.byType(DropdownButton<int>)).dy,
      greaterThan(tester.getBottomLeft(find.text('缓存策略')).dy),
    );
    modeFocus.requestFocus();
    await tester.pump();
    expect(modeFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(switchFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
