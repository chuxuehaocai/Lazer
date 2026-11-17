import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/automix_audio_engine.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/track_transition.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';
import 'package:lazer_nextgen/widgets/text_input_dialog.dart';

import 'support/music_gateway.dart';

class _State extends AppState {
  _State() : super(catalog: Catalog(gateway: TestMusicGateway()));
  final discordWrites = <String>[];
  @override
  Future<void> setDiscordClientId(String value) async =>
      discordWrites.add(value);
}

Future<void> _settings(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: state,
          builder: (_, _) => AppSettingsPage(state: state),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'stored transition names take precedence and old switches still migrate',
    () {
      for (final mode in TrackTransition.values) {
        expect(
          TrackTransition.fromStored(mode.name, legacyAutoMix: !mode.mixes),
          mode,
        );
      }
      expect(
        TrackTransition.fromStored(null, legacyAutoMix: true),
        TrackTransition.autoMix,
      );
      expect(
        TrackTransition.fromStored(null, legacyAutoMix: false),
        TrackTransition.albumGapless,
      );
      expect(
        TrackTransition.fromStored('unknown'),
        TrackTransition.albumGapless,
      );
      const planner = AutoMixTransitionPlanner();
      expect(
        planner.duration(outgoing: const Duration(minutes: 3)),
        const Duration(seconds: 5),
      );
    },
  );

  testWidgets(
    'the actual settings selector exposes three modes and only AutoMix shows its duration',
    (tester) async {
      final state = _State();
      addTearDown(state.dispose);
      await _settings(tester, state);
      final selector = find.byKey(const ValueKey('track-transition-mode'));
      await tester.scrollUntilVisible(
        selector,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(selector);
      await tester.pumpAndSettle();
      for (final mode in TrackTransition.values) {
        expect(find.text(mode.label), findsWidgets);
      }
      await tester.tap(find.text(TrackTransition.autoMix.label).last);
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('automix-duration-slider'));
      expect(row, findsOneWidget);
      final slider = tester.widget<Slider>(
        find.descendant(of: row, matching: find.byType(Slider)),
      );
      expect((slider.min, slider.max, slider.divisions), (1, 13, 12));
      await state.setTrackTransition(TrackTransition.off);
      await tester.pumpAndSettle();
      expect(row, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final save in [false, true]) {
    testWidgets(
      'Discord configuration owns its controller through the exit animation, save=$save',
      (tester) async {
        final state = _State();
        addTearDown(state.dispose);
        await _settings(tester, state);
        final configure = find.text('配置');
        await tester.scrollUntilVisible(
          configure,
          500,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(configure);
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(AppTextInputDialog),
          matching: find.byType(TextField),
        );
        final controller = tester.widget<TextField>(field).controller!;
        await tester.enterText(field, '123456');
        await tester.tap(find.text(save ? '保存' : '取消').last);
        await tester.pump();
        expect(find.byType(AppTextInputDialog), findsOneWidget);
        expect(() => controller.addListener(() {}), returnsNormally);
        await tester.pumpAndSettle();
        expect(find.byType(AppTextInputDialog), findsNothing);
        expect(() => controller.addListener(() {}), throwsFlutterError);
        expect(state.discordWrites, save ? ['123456'] : isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
