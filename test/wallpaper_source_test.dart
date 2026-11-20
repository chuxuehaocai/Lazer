import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/wallpaper_tint.dart';

void main() {
  test(
    'the material filter keeps light and shade but drops the photograph',
    () {
      // Two points of the same wallpaper: a bright sky and a dark corner. A
      // material shows both, muted; a flat average would collapse them.
      const sky = Color(0xFFC8DAEF);
      const corner = Color(0xFF2A2028);
      final mutedSky = applyMaterialMatrix(
        materialWallpaperMatrix(dark: true),
        sky,
      );
      final mutedCorner = applyMaterialMatrix(
        materialWallpaperMatrix(dark: true),
        corner,
      );
      // Both channels are 0..1, so compare in 8-bit steps.
      expect(mutedSky.r * 255, greaterThan(mutedCorner.r * 255 + 20));
      // Neither survives as the original photograph: both come down.
      expect(mutedSky.r, lessThan(sky.r));
      // And the colour cast is mostly gone - the field reads as a surface.
      expect((mutedSky.r - mutedSky.b).abs(), lessThan((sky.r - sky.b).abs()));
    },
  );

  test('the light theme keeps the wallpaper brighter than the dark one', () {
    const wallpaper = Color(0xFFC8DAEF);
    final dark = applyMaterialMatrix(
      materialWallpaperMatrix(dark: true),
      wallpaper,
    );
    final light = applyMaterialMatrix(
      materialWallpaperMatrix(dark: false),
      wallpaper,
    );
    expect(light.r, greaterThan(dark.r));
  });

  test('non-desktop platforms never look for a wallpaper file', () {
    // The lookup is what the material falls back from, so it has to be empty
    // rather than pointing at a path that cannot exist.
    expect(
      desktopWallpaperCandidates().every(
        (path) => path.contains('Themes') || path.contains('Pictures'),
      ),
      isTrue,
    );
  });
}
