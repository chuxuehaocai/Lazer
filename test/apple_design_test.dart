import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/theme/apple_design.dart';

void main() {
  test(
    'Material and Cupertino text consistently use MiSans on every platform',
    () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final theme = buildAppleTheme();
          expect(theme.textTheme.bodyLarge!.fontFamily, 'MiSans');
          expect(theme.textTheme.displayLarge!.fontFamily, 'MiSans');
          final text = theme.cupertinoOverrideTheme!.textTheme!;
          expect(text.textStyle.fontFamily, 'MiSans');
          expect(text.actionTextStyle.fontFamily, 'MiSans');
          expect(text.pickerTextStyle.fontFamily, 'MiSans');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    },
  );
  test('Apple theme exposes semantic system colours and the HIG type ramp', () {
    final ThemeData light = buildAppleTheme();
    final AppleSemanticColors lightSemantics = light
        .extension<AppleSemanticColors>()!;

    expect(light.brightness, Brightness.light);
    expect(light.colorScheme.primary, AppleColors.musicRed);
    expect(light.scaffoldBackgroundColor, Colors.white);
    expect(lightSemantics.groupedBackground, const Color(0xFFF2F2F7));
    expect(lightSemantics.secondaryGroupedBackground, Colors.white);
    expect(light.textTheme.displayLarge?.fontSize, 34);
    expect(light.textTheme.titleLarge?.fontSize, 20);
    expect(light.textTheme.bodyLarge?.fontSize, 17);
    expect(light.textTheme.bodySmall?.fontSize, 13);

    final ThemeData dark = buildAppleTheme(brightness: Brightness.dark);
    final AppleSemanticColors darkSemantics = dark
        .extension<AppleSemanticColors>()!;
    expect(dark.brightness, Brightness.dark);
    expect(dark.scaffoldBackgroundColor, Colors.black);
    expect(darkSemantics.secondaryGroupedBackground, const Color(0xFF1C1C1E));
    expect(darkSemantics.glass.a, lessThan(1));
  });

  test('cover-derived accents do not disturb neutral system surfaces', () {
    const Color seed = Color(0xFF4E8C73);
    final ThemeData fixed = buildAppleTheme(brightness: Brightness.dark);
    final ThemeData seeded = buildAppleTheme(
      brightness: Brightness.dark,
      seedAccent: seed,
    );
    final AppleSemanticColors seededSemantics = seeded
        .extension<AppleSemanticColors>()!;

    expect(seeded.colorScheme.primary, seed);
    expect(seededSemantics.accent, seed);
    expect(seededSemantics.background, fixed.scaffoldBackgroundColor);
    expect(
      seededSemantics.secondaryGroupedBackground,
      fixed.extension<AppleSemanticColors>()!.secondaryGroupedBackground,
    );
    expect(seeded.textTheme.bodyLarge?.fontSize, 17);
  });
}
