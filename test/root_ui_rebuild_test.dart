import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/diagnostics/frame_stats.dart';
import 'package:lazer_nextgen/l10n/app_language.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/app_scroll_behavior.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Audio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

class _State extends AppState {
  _State() : super(independentPlayback: true);
  @override
  Future<void> bootstrap() async {}
  void reportUnrelatedChange() => notifyListeners();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'root ignores unrelated reports but applies global UI preferences',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _State();
      final audio = _Audio();
      final media = SystemMediaController(
        state,
        initialize: () => throw StateError('unexpected media initialization'),
      );
      await tester.pumpWidget(
        LazerApp(state: state, audio: audio, media: media),
      );
      await tester.pump();
      var rootBuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is LazerApp) rootBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      var reports = 0;
      void observeState() => reports++;
      state.addListener(observeState);
      state.reportUnrelatedChange();
      state.toggleShuffle();
      await state.setLyricFontSize(26);
      await tester.pump();
      expect(rootBuilds, 0);
      expect(reports, 3, reason: 'leaf listeners still receive state changes');
      state.removeListener(observeState);

      await state.setLegacyPalette(LegacyPaletteMode.custom);
      await state.setLegacyAccent(const Color(0xFF3366CC));
      await tester.pump();
      expect(
        tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .theme!
            .colorScheme
            .primary,
        buildAppleTheme(
          brightness: Brightness.light,
          seedAccent: const Color(0xFF3366CC),
        ).colorScheme.primary,
      );
      await state.setThemeMode(ThemeMode.dark);
      await tester.pump();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      await state.setLanguage(AppLanguage.english);
      await tester.pump();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('en'),
      );
      await state.setSurface(AppSurface.standard);
      await tester.pump();
      await state.setDpiScale(1.25);
      await tester.pump();
      expect(tester.widget<UiMetrics>(find.byType(UiMetrics)).scale, 1.25);
      await state.setSurface(AppSurface.tv);
      await tester.pump();
      expect(tester.widget<UiMetrics>(find.byType(UiMetrics)).tv, isTrue);
      await state.setScrollRetention(.9);
      await tester.pump();
      final behavior =
          tester.widget<MaterialApp>(find.byType(MaterialApp)).scrollBehavior
              as AppScrollBehavior;
      expect(behavior.retention, .9);
      await state.setShowFrameStats(true);
      await tester.pump();
      expect(find.byType(FrameStatsOverlay), findsOneWidget);
      expect(rootBuilds, greaterThanOrEqualTo(6));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
