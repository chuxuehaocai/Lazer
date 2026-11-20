import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Average colour of the desktop wallpaper, as the window should tint it.
///
/// DWM composites the material, but it only knows a wallpaper Windows owns.
/// A desktop painted by a third-party animated wallpaper still hands DWM a
/// system wallpaper it never re-sampled, so the material falls back to a
/// neutral grey with no colour in it at all — which reads as "Mica is broken".
/// Sampling the same image here keeps the window wallpaper-tinted either way.
Future<Color?> desktopWallpaperTint() => _desktopWallpaperTint ??= _read();

Future<Color?>? _desktopWallpaperTint;

/// Where Windows keeps the image it actually hands the shell. It is a renamed
/// JPEG, so no extension can be trusted into the decoder.
List<String> desktopWallpaperCandidates() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    return const <String>[];
  }
  final String? appData = Platform.environment['APPDATA'];
  final String? profile = Platform.environment['USERPROFILE'];
  return <String>[
    if (appData != null)
      '$appData\\Microsoft\\Windows\\Themes\\TranscodedWallpaper',
    if (profile != null) '$profile\\Pictures\\wallpaper.jpg',
  ];
}

/// Average of [rgba], ignoring transparent pixels. Split out so the maths is
/// testable without a desktop.
Color? averageWallpaperColor(Uint8List rgba) {
  var red = 0;
  var green = 0;
  var blue = 0;
  var weight = 0;
  for (var index = 0; index + 3 < rgba.length; index += 4) {
    final int alpha = rgba[index + 3];
    if (alpha < 8) continue;
    red += rgba[index] * alpha;
    green += rgba[index + 1] * alpha;
    blue += rgba[index + 2] * alpha;
    weight += alpha;
  }
  if (weight == 0) return null;
  return Color.fromARGB(255, red ~/ weight, green ~/ weight, blue ~/ weight);
}

Future<Color?> _read() async {
  for (final String path in desktopWallpaperCandidates()) {
    try {
      final File file = File(path);
      if (!file.existsSync()) continue;
      final Uint8List bytes = await file.readAsBytes();
      // A 24 px strip is plenty: every pixel is averaged, so the size only
      // decides how fast the decode is.
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData? data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (data == null) continue;
      final Color? average = averageWallpaperColor(data.buffer.asUint8List());
      if (average != null) return average;
    } on Object catch (error) {
      // A missing, moved or undecodable wallpaper is not a failure: the
      // material keeps its theme-only look.
      debugPrint('wallpaper tint unavailable at $path: $error');
    }
  }
  return null;
}

@visibleForTesting
void resetWallpaperTintCache() => _desktopWallpaperTint = null;

@visibleForTesting
void cacheWallpaperTint(Color? color) =>
    _desktopWallpaperTint = Future<Color?>.value(color);
