import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../cache/media_cache.dart';

/// NetworkImage adds headers to HttpClient's default User-Agent. The NetEase
/// image CDN rejects that duplicated header, so set each header explicitly.
class ArtworkImage extends ImageProvider<ArtworkImage> {
  const ArtworkImage(this.url);
  final String url;

  @override
  Future<ArtworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  bool operator ==(Object other) => other is ArtworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  ImageStreamCompleter loadImage(
    ArtworkImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _load(ArtworkImage key, ImageDecoderCallback decode) async {
    try {
      final buffer = await ArtworkCache.shared.buffer(key.url);
      try {
        return await decode(buffer);
      } catch (_) {
        await ArtworkCache.shared.evict(key.url);
        rethrow;
      }
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(key);
      rethrow;
    }
  }
}
