import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';

class _ChromeState extends AppState {
  _ChromeState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    titleBarStyle = DesktopTitleBarStyle.inline;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  bool get autoUpdateCheckDue => false;

  @override
  HomeFeed get home => const HomeFeed(
    featuredTracks: [],
    quick: [],
    daily: [],
    playlists: [],
    recommended: [],
    albums: [],
  );
}

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> mountSettingsRoot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    await tester.runAsync(
      () => AppLocalizations.delegate.load(const Locale('en')),
    );
    final state = _ChromeState();
    await state.setIndependentPlayback(true);
    await tester.pumpWidget(
      LazerApp(
        state: state,
        audio: _UnusedAudio(),
        media: SystemMediaController(state),
        windowFrameEnabled: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is AppRailItem && widget.label == '设置',
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> mountSettings(WidgetTester tester) async {
    await mountSettingsRoot(tester);
    await tester.tap(find.text('Interface & layout'));
    await tester.pumpAndSettle();
  }

  /// Every desktop back button sits on the window capsule's row, dropped by the
  /// optical nudge so the two read level instead of merely sharing a centre.
  void expectOnCapsuleRow(WidgetTester tester, Finder back) {
    final capsule = tester.getRect(
      find.byKey(const ValueKey('window-title-minimize')),
    );
    expect(
      tester.getRect(back).center.dy,
      closeTo(capsule.center.dy + kWindowChromeControlNudge, .5),
    );
  }

  testWidgets('a settings back button lines up with the capsule', (
    tester,
  ) async {
    await mountSettings(tester);
    expectOnCapsuleRow(tester, find.byKey(const ValueKey('settings-detail-back')));
  });

  testWidgets('every settings category shares that capsule row', (
    tester,
  ) async {
    await mountSettingsRoot(tester);
    for (final category in ['Network Proxy', 'About Lazer']) {
      final entry = find.text(category);
      expect(entry, findsOneWidget, reason: category);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expectOnCapsuleRow(
        tester,
        find.byKey(const ValueKey('settings-detail-back')),
      );
      await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the desktop detail toolbar back button shares that row', (
    tester,
  ) async {
    await mountSettingsRoot(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is AppRailItem && widget.label == '音乐库',
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('open-local-music'));
    expect(entry, findsOneWidget);
    await tester.tap(entry.first);
    await tester.pumpAndSettle();
    expectOnCapsuleRow(tester, find.byTooltip('Back').first);
  });

  testWidgets('a page command moves into the capsule, not under it', (
    tester,
  ) async {
    await mountSettings(tester);
    await tester.tap(find.text('Font customization'));
    await tester.pumpAndSettle();

    final actions = find.byKey(const ValueKey('settings-capsule-actions'));
    expect(actions, findsOneWidget);
    // The text command, the hairline and the caption cluster share one pill.
    expect(
      find.descendant(
        of: actions,
        matching: find.byKey(const ValueKey('reset-all-fonts')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('window-chrome-action-divider')),
      findsOneWidget,
    );
    // The reset button sits inside the capsule's band, left of the caption
    // cluster, instead of being painted over by it.
    final reset = tester.getRect(find.byKey(const ValueKey('reset-all-fonts')));
    final caption = tester.getRect(
      find.byKey(const ValueKey('window-title-minimize')),
    );
    expect(reset.center.dy, closeTo(caption.center.dy, 8));
    expect(reset.right, lessThanOrEqualTo(caption.left));
    // Nothing is left in the page header row.
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('reset-all-fonts')),
        matching: find.byType(WindowChromeActions),
      ),
      findsOneWidget,
    );
  });
}
