import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the material mode paints nothing itself', () async {
    final state = AppState();
    addTearDown(state.dispose);
    expect(state.backgroundOpacity, 1);

    await state.setAppBackground(AppBackgroundMode.windowsMica);
    // DWM composites the material into the window. Anything this app painted
    // here would cover those pixels - which is what made the surface look like
    // a flat sheet instead of a material.
    expect(state.backgroundOpacity, 0);

    await state.setAppBackground(AppBackgroundMode.nowPlayingDynamic);
    // The material's default must not leak into the canvas modes, which paint
    // their own artwork and expect a full-strength background.
    expect(state.backgroundOpacity, 1);
    expect(state.backgroundOpacityChosen, isFalse);
  });

  test('the player material follows the same rule', () async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.setPlayerBackground(AppBackgroundMode.windowsMica);
    expect(state.playerBackgroundOpacity, 0);
    await state.setPlayerBackground(AppBackgroundMode.nowPlayingDynamic);
    expect(state.playerBackgroundOpacity, 1);
  });

  test('an opacity the listener picked survives every mode switch', () async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.setBackgroundOpacity(.7);
    expect(state.backgroundOpacityChosen, isTrue);

    await state.setAppBackground(AppBackgroundMode.windowsMica);
    expect(state.backgroundOpacity, .7);
    await state.setAppBackground(AppBackgroundMode.solidColor);
    expect(state.backgroundOpacity, .7);
  });

  test('a stored value keeps its position in the shared direction', () async {
    for (final (double stored, double expected) in <(double, double)>[
      (1.0, 1.0),
      (0.0, 0.0),
      (.25, .25),
    ]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.lazer_legacy_background': 'windowsMica',
        'flutter.lazer_background_opacity': stored,
        'flutter.lazer_background_opacity_direction': false,
      });
      final state = AppState();
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.backgroundOpacity, closeTo(expected, .001));
    }
  });

  test('the old inverted slider is converted exactly once', () async {
    // Old builds stored the *material's* share, so 1.0 meant "no veil at all".
    // That intent is now the shared direction's 0.0.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.lazer_legacy_background': 'windowsMica',
      'flutter.lazer_background_opacity': 1.0,
    });
    final state = AppState();
    addTearDown(state.dispose);
    await state.bootstrap();
    expect(state.backgroundOpacity, 0);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lazer_background_opacity_direction'), isFalse);
    expect(prefs.getDouble('lazer_background_opacity'), 0);

    final restored = AppState();
    addTearDown(restored.dispose);
    await restored.bootstrap();
    expect(restored.backgroundOpacity, 0);
  });

  test('a half-open slider keeps its position across the migration', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.lazer_legacy_background': 'windowsMica',
      'flutter.lazer_background_opacity': .25,
    });
    final state = AppState();
    addTearDown(state.dispose);
    await state.bootstrap();
    // 25% material under the old reading is a 75% veil now.
    expect(state.backgroundOpacity, closeTo(.75, .001));
  });

  test('a fresh material install claims no choice', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.lazer_legacy_background': 'windowsMica',
    });
    final state = AppState();
    addTearDown(state.dispose);
    await state.bootstrap();
    expect(state.backgroundOpacity, 0);
    expect(state.backgroundOpacityChosen, isFalse);
  });

  test('a canvas mode still starts at full strength', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.lazer_legacy_background': 'nowPlayingDynamic',
    });
    final state = AppState();
    addTearDown(state.dispose);
    await state.bootstrap();
    expect(state.backgroundOpacity, 1);
  });
}
