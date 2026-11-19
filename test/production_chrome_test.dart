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
import 'package:lazer_nextgen/tv/large_screen_chrome.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:lazer_nextgen/widgets/capsule_navigation_bar.dart';
import 'package:lazer_nextgen/widgets/settings_detail.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';

class _RootState extends AppState {
  _RootState() {
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

  testWidgets(
    'production Inline rail shares the title row without double inset',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          calls.add(call.method);
          return call.method.startsWith('is') ? false : null;
        },
      );
      await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('en')),
      );
      final state = _RootState();
      await state.setIndependentPlayback(true);
      await tester.pumpWidget(
        LazerApp(
          state: state,
          audio: _UnusedAudio(),
          media: SystemMediaController(state),
          windowFrameEnabled: true,
        ),
      );
      await tester.pump();
      final rail = find.byKey(const ValueKey('desktop-sidebar'));
      final home = find.byType(AppHomePage);
      expect(tester.getTopLeft(rail).dy, 0);
      // The capsule floats over the page, and its band is reserved as layout:
      // the page starts below the band so a scrolled list stops there instead of
      // painting under the capsule, and the page is not given the band a second
      // time as scroll padding.
      expect(tester.getTopLeft(home).dy, kInlineChromeInset);
      expect(tester.widget<AppHomePage>(home).topInset, 0);
      expect(tester.getTopLeft(find.text('Lazer').first).dy, lessThan(40));
      final capsule = tester.getRect(
        find.byKey(const ValueKey('window-title-minimize')),
      );
      expect(capsule.top, kWindowChromeTop);

      // Inline chrome leaves the top of the window to the page, so the page's
      // own header is the drag handle: the wordmark band wraps, and pages that
      // open with a large title wrap that title.
      expect(
        find.ancestor(
          of: find.text('Lazer').first,
          matching: find.byType(WindowDragArea),
        ),
        findsOneWidget,
      );
      calls.clear();
      await tester.drag(find.text('Lazer').first, const Offset(0, 48));
      await tester.pump();
      expect(calls, contains('startDragging'));
      calls.clear();

      // The capsule itself is the title bar: dragging over a caption button
      // moves the window, while a plain click still presses that button.
      await tester.drag(
        find.byKey(const ValueKey('window-title-minimize')),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expect(calls, contains('startDragging'));
      expect(calls, isNot(contains('minimize')));
      calls.clear();

      // A page title lives inside the page's own scroll view, whose vertical
      // drag recognizer would otherwise win the arena: dragging the title has
      // to move the window, not the page.
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is AppRailItem && widget.label == '音乐库',
        ),
      );
      await tester.pumpAndSettle();
      final title = find.descendant(
        of: find.byType(AppLibraryPage),
        matching: find.byType(ApplePageTitle),
      );
      final before = tester.getRect(title).top;
      calls.clear();
      await tester.drag(title, const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(calls, contains('startDragging'));
      expect(
        tester.getRect(title).top,
        closeTo(before, .01),
        reason: 'the page must not scroll while the window is dragged',
      );
      calls.clear();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is AppRailItem && widget.label == '设置',
        ),
      );
      await tester.pumpAndSettle();

      // The strip above the page title is the title bar too: a press on empty
      // chrome at the very top of the window drags it, while the same drag
      // lower down belongs to the page.
      final pane = tester.getRect(
        find.byKey(const ValueKey('desktop-content-safe-area')),
      );
      calls.clear();
      await tester.dragFrom(Offset(pane.center.dx, 20), const Offset(0, 50));
      await tester.pumpAndSettle();
      expect(calls, contains('startDragging'));
      calls.clear();
      await tester.dragFrom(
        Offset(pane.center.dx, pane.center.dy),
        const Offset(0, 50),
      );
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('startDragging')));
      calls.clear();

      // Floating chrome must never sit on a page control, including embedded
      // settings details that carry their own back affordance.
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is AppRailItem && widget.label == '设置',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Interface & layout'));
      await tester.pumpAndSettle();

      // The capsule's material is a setting, not a constant: blur on/off, blur
      // strength, tint opacity, and a custom tint that only unlocks the palette
      // after it is switched on.
      for (final String key in <String>[
        'window-chrome-blur-switch',
        'window-chrome-blur-slider',
        'window-chrome-opacity-slider',
        'window-chrome-color-switch',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
      }
      expect(
        find.byKey(const ValueKey('window-chrome-color-setting')),
        findsNothing,
      );
      expect(state.windowChromeColor, isNull);
      final colorSwitch = find.byKey(
        const ValueKey('window-chrome-color-switch'),
      );
      await tester.ensureVisible(colorSwitch);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: colorSwitch, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      expect(state.windowChromeColor, isNotNull);
      expect(
        find.byKey(const ValueKey('window-chrome-color-swatch')),
        findsOneWidget,
      );

      final back = find.byKey(const ValueKey('settings-detail-back'));
      expect(back.hitTestable(), findsOneWidget);
      expect(tester.getRect(back).right, lessThan(capsule.left));
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call == 'startDragging'), isEmpty);

      // A pushed settings page keeps the same relationship while dialogs
      // remain below the caption cluster and can still receive pointer input.
      final context = tester.element(rail);
      final navigator = Navigator.of(context);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const SettingsDetailScaffold(
            title: 'Fixture route',
            headerTitle: true,
            child: Text('Route content'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(back.hitTestable(), findsOneWidget);
      expect(tester.getRect(back).right, lessThan(capsule.left));
      await tester.tap(back);
      await tester.pumpAndSettle();

      var dialogActivated = false;
      showDialog<void>(
        context: tester.element(rail),
        builder: (context) => AlertDialog(
          title: const Text('Fixture dialog'),
          actions: [
            TextButton(
              key: const ValueKey('fixture-dialog-action'),
              onPressed: () {
                dialogActivated = true;
                Navigator.pop(context);
              },
              child: const Text('Done'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final dialogAction = find.byKey(const ValueKey('fixture-dialog-action'));
      expect(dialogAction.hitTestable(), findsOneWidget);
      await tester.tap(dialogAction);
      await tester.pumpAndSettle();
      expect(dialogActivated, isTrue);

      // Switching the frame and layout changes the real production tree on the
      // next frame; an Inline-only inset must not leak into classic mode.
      await state.setTitleBarStyle(DesktopTitleBarStyle.classic);
      await tester.pump();
      expect(tester.getTopLeft(rail).dy, 40);
      await state.setTitleBarStyle(DesktopTitleBarStyle.inline);
      await state.setLayoutStyle(AppLayoutStyle.tv);
      await tester.pump();
      await tester.pump();
      expect(rail, findsNothing);
      expect(find.byType(LargeScreenNavBar), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(LargeScreenNavBar)).dy,
        greaterThanOrEqualTo(56 * kLargeScreenComponentScale),
      );
      await state.setLayoutStyle(AppLayoutStyle.phone);
      await tester.pump();
      await tester.pump();
      expect(find.byType(LargeScreenNavBar), findsNothing);
      expect(rail, findsNothing);
      for (final name in ['minimize', 'fullscreen', 'close']) {
        expect(find.byKey(ValueKey('window-title-$name')), findsNothing);
      }
      expect(
        MediaQuery.paddingOf(
          tester.element(find.byType(CapsuleNavigationBar)),
        ).top,
        0,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(CapsuleNavigationBar),
          matching: find.byIcon(Icons.library_music_outlined),
        ),
      );
      await tester.pumpAndSettle();
      final libraryHost = find.ancestor(
        of: find.byType(AppLibraryPage),
        matching: find.byType(SettingsDetailHost),
      );
      expect(tester.widget<SettingsDetailHost>(libraryHost).compact, isTrue);
      await state.setLayoutStyle(AppLayoutStyle.desktop);
      await tester.pump();
      await tester.pump();
      expect(rail, findsOneWidget);
      expect(tester.getTopLeft(rail).dy, 0);
      expect(
        find.byKey(const ValueKey('window-title-minimize')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.widget<SettingsDetailHost>(libraryHost).compact, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
