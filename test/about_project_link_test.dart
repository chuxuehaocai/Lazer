import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/legacy/legacy_settings_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/large_screen_pages.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/updates/update_checker.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';

const _channel = MethodChannel('dev.naominet.lazer/updates');
final _projectLink = find.byKey(const ValueKey('open-github-project'));

Future<void> _showAbout(
  WidgetTester tester, {
  required bool tv,
  double width = 390,
}) async {
  tester.view.physicalSize = tv ? const Size(1280, 720) : Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState()..surface = tv ? AppSurface.tv : AppSurface.standard;
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      home: UiScaling(
        state: state,
        child: TvTraversalScope(
          child: Scaffold(
            body: tv
                ? LargeScreenSettingsPage(state: state, onOpenLocalMusic: () {})
                : LegacySettingsPage(state: state),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    _projectLink,
    600,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 40,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (label, tv, width) in [
    ('phone', false, 390.0),
    ('desktop layout', false, 1280.0),
    ('TV remote', true, 1280.0),
  ]) {
    testWidgets(
      '$label About entry opens the project homepage',
      (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _channel,
          (call) async {
            calls.add(call);
            return true;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            _channel,
            null,
          ),
        );
        await _showAbout(tester, tv: tv, width: width);
        expect(find.text('GitHub 项目'), findsOneWidget);
        expect(
          find.descendant(
            of: _projectLink,
            matching: find.text(UpdateChecker.repositoryUrl),
          ),
          findsOneWidget,
        );
        if (tv) {
          final region = find
              .descendant(of: _projectLink, matching: find.byType(MouseRegion))
              .first;
          Focus.of(tester.element(region)).requestFocus();
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: _projectLink,
              matching: find.byType(TvFocusOutline),
            ),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(_projectLink);
        }
        await tester.pump();
        expect(calls, hasLength(1));
        expect(calls.single.method, 'openUrl');
        expect(calls.single.arguments, {
          'url': 'https://github.com/chuxuehaocai/Lazer',
        });
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        if (!tv) TargetPlatform.iOS,
      }),
    );
  }

  testWidgets(
    'a missing browser shows the project URL instead of failing silently',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        (_) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _channel,
          null,
        ),
      );
      await _showAbout(tester, tv: false);
      await tester.tap(_projectLink);
      await tester.pump();
      expect(
        find.text('无法打开浏览器，请手动访问 https://github.com/chuxuehaocai/Lazer'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
