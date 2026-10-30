import 'package:flutter/material.dart';

import '../utils/artwork.dart';
import 'artwork_image.dart';

/// Displays artwork from the media cache, decoded at the size it is painted.
///
/// The previous implementation always requested the 1024 px CDN rendition, so
/// a 44 dp queue thumbnail decoded a 1024² image. Sizing the request to the
/// painted size keeps the image cache small and removes decode work from the
/// scroll path.
class PlateArt extends StatelessWidget {
  const PlateArt({
    super.key,
    required this.seed,
    this.accent = 0,
    this.radius,
    this.coverUrl,
    this.size,
  });

  final int seed;
  final int accent;
  final BorderRadius? radius;
  final String? coverUrl;

  /// Painted edge in logical pixels; drives the CDN rendition.
  final double? size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? url = artworkUrlForSize(
      coverUrl,
      logicalEdge: size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    final Widget fallback = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: scheme.onSurfaceVariant,
          size: (size ?? 48) * 0.38,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: radius ?? BorderRadius.zero,
      child: url == null || url.isEmpty
          ? fallback
          : Image(
              image: ResizeImage.resizeIfNeeded(
                size == null
                    ? null
                    : (size! * MediaQuery.devicePixelRatioOf(context)).ceil(),
                size == null
                    ? null
                    : (size! * MediaQuery.devicePixelRatioOf(context)).ceil(),
                ArtworkImage(url),
              ),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? _) =>
                      fallback,
            ),
    );
  }
}
