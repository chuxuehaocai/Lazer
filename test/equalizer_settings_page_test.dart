import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'HiFi exposes an equalizer page whose presets and band edits persist',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(body: HifiSettingsSection(state: state)),
        ),
      );
      expect(
        tester.getTopLeft(find.text('高保真播放')).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('audio-engine-choice')))
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-equalizer-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(EqualizerSettingsPage), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(state.hifiSettings.eqActive, isTrue);
      await tester.tap(find.byKey(const ValueKey('hifi-eq-preset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('摇滚').last);
      await tester.pumpAndSettle();
      expect(state.hifiSettings.equalizer.matchingPresetId, 'rock');
      final firstBand = find.byKey(const ValueKey('hifi-eq-band-0'));
      await tester.ensureVisible(firstBand);
      await tester.pumpAndSettle();
      await tester.drag(firstBand, const Offset(0, -25));
      await tester.pumpAndSettle();
      final eq = state.hifiSettings.equalizer;
      expect(eq.effectiveBands.first.gainDb, greaterThan(4));
      final prefs = await SharedPreferences.getInstance();
      expect(
        HifiEqualizerState.decode(prefs.getString('hifi_equalizer')).encode(),
        eq.encode(),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
