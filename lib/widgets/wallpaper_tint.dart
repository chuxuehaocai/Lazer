import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The desktop wallpaper, as the window should show it.
///
/// DWM composites the material, but it only knows a wallpaper Windows owns. A
/// desktop painted by a third-party animated wallpaper still hands DWM a system
/// wallpaper it never re-sampled, so the material falls back to a neutral sheet
/// with no wallpaper in it at all — which reads as "Mica is broken". Sampling
/// the same image here keeps the window a wallpaper material either way.
Future<ui.Image?> desktopWallpaperImage() => _desktopWallpaperImage ??= _read();

Future<ui.Image?>? _desktopWallpaperImage;

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

/// Desaturate and dim a wallpaper into the muted field a system material shows.
///
/// Mica is not the wallpaper: it is the wallpaper heavily blurred, drained of
/// most of its colour and then tinted towards the window surface. Painting the
/// original image would put a photograph behind the UI; painting its average
/// colour would put a flat sheet there. This is the filter in between, and it
/// keeps the soft light and shade that make the surface read as a material.
List<double> materialWallpaperMatrix({required bool dark}) {
  // Luminance weights, the same ones the framework uses for grey conversion.
  const double lr = 0.2126, lg = 0.7152, lb = 0.0722;
  const double saturation = .12;
  final double gain = dark ? .5 : 1.0;
  double mix(double coefficient) => coefficient * gain;
  return <double>[
    mix(lr * (1 - saturation) + saturation),
    mix(lg * (1 - saturation)),
    mix(lb * (1 - saturation)),
    0,
    0,
    mix(lr * (1 - saturation)),
    mix(lg * (1 - saturation) + saturation),
    mix(lb * (1 - saturation)),
    0,
    0,
    mix(lr * (1 - saturation)),
    mix(lg * (1 - saturation)),
    mix(lb * (1 - saturation) + saturation),
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];
}

ColorFilter materialWallpaperFilter({required bool dark}) =>
    ColorFilter.matrix(materialWallpaperMatrix(dark: dark));

/// Applies a colour matrix to one colour. Exposed so the material's tint can be
/// asserted without rendering an image.
Color applyMaterialMatrix(List<double> matrix, Color color) {
  double channel(int row) {
    final double value =
        matrix[row * 5] * color.r +
        matrix[row * 5 + 1] * color.g +
        matrix[row * 5 + 2] * color.b +
        matrix[row * 5 + 3] * color.a +
        matrix[row * 5 + 4];
    return value.clamp(0.0, 1.0);
  }

  return Color.from(
    alpha: channel(3),
    red: channel(0),
    green: channel(1),
    blue: channel(2),
  );
}

Future<ui.Image?> _read() async {
  for (final String path in desktopWallpaperCandidates()) {
    try {
      final File file = File(path);
      if (!file.existsSync()) continue;
      final Uint8List bytes = await file.readAsBytes();
      // 96 px across is the whole point: the material is a blurred wallpaper,
      // and upscaling this back to the window is what blurs it. Decoding the
      // full 6400 px image would cost tens of megabytes for the same pixels.
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 96,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } on Object catch (error) {
      // A missing, moved or undecodable wallpaper is not a failure: the
      // material keeps its theme-only look.
      debugPrint('wallpaper source unavailable at $path: $error');
    }
  }
  return null;
}

@visibleForTesting
void resetWallpaperImageCache() => _desktopWallpaperImage = null;

@visibleForTesting
void cacheWallpaperImage(ui.Image? image) =>
    _desktopWallpaperImage = Future<ui.Image?>.value(image);
