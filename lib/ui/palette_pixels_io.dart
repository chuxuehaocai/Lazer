import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../cache/media_cache.dart';

/// Decoded cover pixels used for palette extraction.
class PalettePixels {
  const PalettePixels(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// Native path: decode through `dart:ui` and read the frame as raw RGBA.
Future<PalettePixels?> readPalettePixels(String url) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ArtworkCache.shared.buffer(url);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    const int edge = 96;
    final double scale = math.min(
      1,
      edge / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (data == null) return null;
    return PalettePixels(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      image.width,
      image.height,
    );
  } catch (_) {
    await ArtworkCache.shared.evict(url);
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
