import 'package:flutter/material.dart';

double colorContrast(Color foreground, Color background) {
  final double a = foreground.computeLuminance();
  final double b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

/// Preserve the artwork hue while moving its tone into the readable range.
Color adaptiveAccent(Color seed, Color surface, {double minimum = 4.5}) {
  final Color opaque = seed.withValues(alpha: 1);
  if (colorContrast(opaque, surface) >= minimum) return opaque;
  final HSLColor hsl = HSLColor.fromColor(opaque);
  final double destination = surface.computeLuminance() < .18 ? 1 : 0;
  double low = 0, high = 1;
  Color candidate = hsl.withLightness(destination).toColor();
  for (int i = 0; i < 24; i++) {
    final double t = (low + high) / 2;
    final Color next = hsl
        .withLightness(hsl.lightness + (destination - hsl.lightness) * t)
        .toColor();
    if (colorContrast(next, surface) >= minimum) {
      candidate = next;
      high = t;
    } else {
      low = t;
    }
  }
  return candidate;
}

Color contrastingLabel(Color surface) =>
    colorContrast(Colors.white, surface) >= colorContrast(Colors.black, surface)
    ? Colors.white
    : Colors.black;

Color backgroundFromTheme(Color accent, Brightness brightness) =>
    HSLColor.fromColor(accent)
        .withSaturation(.22)
        .withLightness(brightness == Brightness.dark ? .12 : .91)
        .toColor();
