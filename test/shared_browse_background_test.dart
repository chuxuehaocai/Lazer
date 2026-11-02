import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/ui/font_settings_page.dart';
import 'package:lazer_nextgen/ui/shortcut_settings_page.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section.dart';
import 'package:lazer_nextgen/widgets/shared_browse_background.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'auxiliary pages retain the same animated backdrop and resume after navigation',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      final navigation = BrowseNavigationObserver();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          navigatorKey: navigator,
          navigatorObservers: [navigation],
          builder: (context, child) => SharedBrowseBackground(
            state: state,
            navigation: navigation,
            child: child!,
          ),
          home: const Scaffold(body: Text('Home')),
        ),
      );
      await tester.pump();
      final original = tester.element(find.byType(AppAlbumBackdrop));
      bool running() => tester
          .widget<TickerMode>(
            find
                .ancestor(
                  of: find.byType(AppAlbumBackdrop),
                  matching: find.byType(TickerMode),
                )
                .first,
          )
          .enabled;
      state.browseTransitionActive.value = true;
      await tester.pump();
      expect(running(), isFalse);
      for (final page in [
        FontSettingsPage(state: state),
        ShortcutSettingsPage(state: state),
        EqualizerSettingsPage(state: state),
      ]) {
        navigator.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => page),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(find.byType(AppAlbumBackdrop), findsOneWidget);
        expect(
          identical(tester.element(find.byType(AppAlbumBackdrop)), original),
          isTrue,
        );
        expect(navigation.rootVisible.value, isFalse);
        expect(
          running(),
          isTrue,
          reason:
              'a covered root animation must not freeze the new page background',
        );
        final scaffold = tester.widget<Scaffold>(
          find
              .descendant(
                of: find.byWidget(page),
                matching: find.byType(Scaffold),
              )
              .first,
        );
        expect(scaffold.backgroundColor, Colors.transparent);
        navigator.currentState!.pop();
        await tester.pump();
        // Let the 500 ms route transition finish on the following frame.
        await tester.pump(const Duration(milliseconds: 520));
        await tester.pump();
      }
      state.browseTransitionActive.value = false;
      await tester.pump();
      expect(
        navigation.moving.value,
        isFalse,
        reason: 'navigation must stop gating the background after pop',
      );
      expect(state.playerPresented.value, isFalse);
      expect(running(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      navigation.dispose();
    },
  );
}
