import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'entering the material mode starts layered, leaving restores the canvas',
    () async {
      final state = AppState();
      addTearDown(state.dispose);
      expect(state.backgroundOpacity, 1);

      await state.setAppBackground(AppBackgroundMode.windowsMica);
      // A bare hand-over to DWM renders one flat sheet on a desktop whose
      // wallpaper the shell has no tint for, so the material starts behind a
      // theme veil instead.
      expect(state.backgroundOpacity, kMaterialBackgroundOpacity);

      await state.setAppBackground(AppBackgroundMode.nowPlayingDynamic);
      // The material's default must not leak into the canvas modes, which paint
      // their own artwork and expect a full-strength background.
      expect(state.backgroundOpacity, 1);
      expect(state.backgroundOpacityChosen, isFalse);
    },
  );

  test('the player material follows the same rule', () async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.setPlayerBackground(AppBackgroundMode.windowsMica);
    expect(state.playerBackgroundOpacity, kMaterialBackgroundOpacity);
    await state.setPlayerBackground(AppBackgroundMode.nowPlayingDynamic);
    expect(state.playerBackgroundOpacity, 1);
  });

  test('an opacity the listener picked survives every mode switch', () async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.setBackgroundOpacity(.6);
    expect(state.backgroundOpacityChosen, isTrue);

    await state.setAppBackground(AppBackgroundMode.windowsMica);
    expect(state.backgroundOpacity, .6);
    await state.setAppBackground(AppBackgroundMode.solidColor);
    expect(state.backgroundOpacity, .6);
  });
}
