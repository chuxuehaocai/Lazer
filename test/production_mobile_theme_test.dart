import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/capsule_navigation_bar.dart';
import 'package:lazer_nextgen/widgets/shared_browse_background.dart';

class _PreviewState extends AppState {
  @override
  Future<void> bootstrap() async {}

  @override
  bool get autoUpdateCheckDue => false;
}

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'production shell, pushed routes and dialogs share the phone theme',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('en')),
      );
      final state = _PreviewState()
        ..autoDpiScale = false
        ..themeMode = ThemeMode.dark;
      await state.setIndependentPlayback(true);
      await tester.pumpWidget(
        LazerApp(
          state: state,
          audio: _UnusedAudio(),
          media: SystemMediaController(state),
          windowFrameEnabled: false,
        ),
      );
      await tester.pumpAndSettle();
      final navContext = tester.element(find.byType(CapsuleNavigationBar));
      expect(AppleSemanticColors.of(navContext).accent, AppleColors.musicRed);
      final canvas = find
          .descendant(
            of: find.byType(SharedBrowseBackground),
            matching: find.byType(ColoredBox),
          )
          .first;
      expect(
        tester.widget<ColoredBox>(canvas).color,
        AppleColors.mobileDarkCanvas,
      );

      final navigator = Navigator.of(navContext);
      ThemeData? routeTheme;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (context) {
            routeTheme = Theme.of(context);
            return const Scaffold(body: Text('Pushed route'));
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(routeTheme!.colorScheme.primary, AppleColors.musicRed);
      ThemeData? dialogTheme;
      showDialog<void>(
        context: tester.element(find.text('Pushed route')),
        builder: (context) {
          dialogTheme = Theme.of(context);
          return const AlertDialog(content: Text('Phone dialog'));
        },
      );
      await tester.pumpAndSettle();
      expect(dialogTheme!.colorScheme.primary, AppleColors.musicRed);
      navigator.pop();
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(1280, 900);
      await tester.pumpAndSettle();
      expect(routeTheme!.colorScheme.primary, AppleColors.lazerBlue);
      await state.setLayoutStyle(AppLayoutStyle.phone);
      await tester.pumpAndSettle();
      expect(routeTheme!.colorScheme.primary, AppleColors.musicRed);
      expect(routeTheme!.extension<AppThemePresentation>()!.compact, isTrue);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(CapsuleNavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
