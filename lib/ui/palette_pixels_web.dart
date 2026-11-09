// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

import '../cache/media_cache.dart';

/// Decoded cover pixels used for palette extraction.
class PalettePixels {
  const PalettePixels(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// Browser path: draw the cover on a canvas and read its pixels.
///
/// CanvasKit's `Image.toByteData` produced colours that did not match the
/// artwork on the web, so palette extraction goes through the browser's own
/// image decoder instead.
Future<PalettePixels?> readPalettePixels(String url) async {
  try {
    final Uint8List bytes = await ArtworkCache.shared.bytes(url);
    final String objectUrl = html.Url.createObjectUrl(
      html.Blob(<Object>[bytes]),
    );
    try {
      final image = html.ImageElement()..crossOrigin = 'anonymous';
      final Future<bool> loaded = image.onLoad.first.then((_) => true);
      final Future<bool> failed = image.onError.first.then((_) => false);
      image.src = objectUrl;
      if (!await Future.any(<Future<bool>>[loaded, failed])) return null;
      final int width = image.naturalWidth;
      final int height = image.naturalHeight;
      if (width <= 0 || height <= 0) return null;
      const int edge = 96;
      final double scale = math.min(1, edge / math.max(width, height));
      final int targetWidth = math.max(1, (width * scale).round());
      final int targetHeight = math.max(1, (height * scale).round());
      final canvas = html.CanvasElement(
        width: targetWidth,
        height: targetHeight,
      );
      canvas.context2D.drawImageScaled(image, 0, 0, targetWidth, targetHeight);
      final data = canvas.context2D.getImageData(0, 0, targetWidth, targetHeight);
      return PalettePixels(
        Uint8List.fromList(data.data),
        targetWidth,
        targetHeight,
      );
    } finally {
      html.Url.revokeObjectUrl(objectUrl);
    }
  } catch (_) {
    return null;
  }
}
