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
import 'package:lazer_nextgen/widgets/capsule_navigation_bar.dart';
import 'package:lazer_nextgen/widgets/settings_detail.dart';

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
      expect(tester.getTopLeft(home).dy, 56);
      expect(tester.widget<AppHomePage>(home).topInset, 0);
      expect(tester.getTopLeft(find.text('Lazer').first).dy, lessThan(40));

      // The title's hit area stays above page controls, including embedded
      // settings details which do not have their own route/AppBar safe area.
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is AppRailItem && widget.label == '设置',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Interface & layout'));
      await tester.pumpAndSettle();
      final back = find.byKey(const ValueKey('settings-detail-back'));
      expect(tester.getTopLeft(back).dy, greaterThanOrEqualTo(56));
      expect(back.hitTestable(), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call == 'startDragging'), isEmpty);

      // A pushed settings page consumes the same inset once, while dialogs
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
      expect(tester.getTopLeft(back).dy, greaterThanOrEqualTo(56));
      expect(back.hitTestable(), findsOneWidget);
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
