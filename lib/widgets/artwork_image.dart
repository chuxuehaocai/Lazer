import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../cache/media_cache.dart';
import '../utils/artwork.dart';

/// NetworkImage adds headers to HttpClient's default User-Agent. The NetEase
/// image CDN rejects that duplicated header, so set each header explicitly.
class ArtworkImage extends ImageProvider<ArtworkImage> {
  const ArtworkImage(this.url, {this.targetSize})
    : assert(targetSize == null || targetSize > 0);

  factory ArtworkImage.forSize(
    String url, {
    double? logicalEdge,
    double devicePixelRatio = 1,
  }) {
    final pixels = artworkPixelSize(logicalEdge, devicePixelRatio);
    return ArtworkImage(
      enlargedArtworkUrl(url, sizePx: pixels) ?? url,
      targetSize: pixels,
    );
  }

  final String url;

  /// Desired physical pixels on the shorter edge for square artwork crops.
  /// Extreme panoramas limit their longer edge to four times this size, so a
  /// thumbnail cannot retain a huge texture. Shared rendition sizes also
  /// share one decoded image across widgets.
  final int? targetSize;

  @override
  Future<ArtworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  bool operator ==(Object other) =>
      other is ArtworkImage &&
      other.url == url &&
      other.targetSize == targetSize;

  @override
  int get hashCode => Object.hash(url, targetSize);

  @override
  ImageStreamCompleter loadImage(
    ArtworkImage key,
    ImageDecoderCallback decode,
  ) {
    final completer = MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1,
      debugLabel: key.url,
    );
    // A recycled thumbnail can detach before its pending request fails. Keep
    // cache cleanup as an ephemeral listener, matching Flutter's ResizeImage.
    completer.addEphemeralErrorListener((error, stack) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  Future<ui.Codec> _load(ArtworkImage key, ImageDecoderCallback decode) async {
    final buffer = await ArtworkCache.shared.buffer(key.url);
    try {
      final target = key.targetSize;
      return await decode(
        buffer,
        getTargetSize: target == null
            ? null
            : (width, height) {
                final scale = math.min(
                  1.0,
                  math.min(
                    target / math.min(width, height),
                    (target * 4) / math.max(width, height),
                  ),
                );
                return ui.TargetImageSize(
                  width: math.max(1, (width * scale).ceil()),
                  height: math.max(1, (height * scale).ceil()),
                );
              },
      );
    } catch (_) {
      await ArtworkCache.shared.evict(key.url);
      rethrow;
    }
  }
}
