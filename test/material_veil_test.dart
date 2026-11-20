import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/wallpaper_tint.dart';

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
    await state.setBackgroundOpacity(.7);
    expect(state.backgroundOpacityChosen, isTrue);

    await state.setAppBackground(AppBackgroundMode.windowsMica);
    expect(state.backgroundOpacity, .7);
    await state.setAppBackground(AppBackgroundMode.solidColor);
    expect(state.backgroundOpacity, .7);
  });

  test(
    'a stored 1.0 from the inverted slider means most material allowed',
    () async {
      // Every listener who used the old build has this on disk: the stored
      // number was the material's share, so 1.0 meant "no veil at all". Read
      // literally it would hand the whole window to DWM, which paints a flat grey
      // rectangle on a desktop it never sampled - exactly the reported bug. The
      // old maximum therefore lands on the most material this mode still allows.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.lazer_legacy_background': 'windowsMica',
        'flutter.lazer_background_opacity': 1.0,
      });
      final state = AppState();
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.backgroundOpacity, kMaterialVeilMin);
      expect(state.backgroundOpacityChosen, isTrue);

      // The value is written back in the other direction, so a later launch reads
      // it as-is and the migration never runs twice.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lazer_background_opacity_direction'), isFalse);
      expect(prefs.getDouble('lazer_background_opacity'), kMaterialVeilMin);

      final restored = AppState();
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.backgroundOpacity, kMaterialVeilMin);
    },
  );

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

  test('a material veil never lands on either useless end', () async {
    for (final (double stored, double expected) in <(double, double)>[
      (1.0, kMaterialVeilMin),
      (0.0, kMaterialVeilMax),
    ]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.lazer_legacy_background': 'windowsMica',
        'flutter.lazer_background_opacity': stored,
      });
      final state = AppState();
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.backgroundOpacity, closeTo(expected, .001));
    }
  });

  test('a fresh install starts layered without claiming a choice', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.lazer_legacy_background': 'windowsMica',
    });
    final state = AppState();
    addTearDown(state.dispose);
    await state.bootstrap();
    expect(state.backgroundOpacity, kMaterialBackgroundOpacity);
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

  test('the material is the wallpaper field, not a film of its average', () {
    // The reported bug: a flat veil over the whole window. The filter has to
    // leave light and shade in the field, so two very different points of one
    // wallpaper stay different after it.
    final dark = materialWallpaperMatrix(dark: true);
    final sky = applyMaterialMatrix(dark, const Color(0xFFC8DAEF));
    final corner = applyMaterialMatrix(dark, const Color(0xFF2A2028));
    expect(sky.r * 255, greaterThan(corner.r * 255 + 20));
  });
}
