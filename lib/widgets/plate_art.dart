import 'package:flutter/material.dart';

import '../utils/artwork.dart';
import '../animation/motion_snapshot.dart';
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
    this.image,
  });

  final int seed;
  final int accent;
  final BorderRadius? radius;
  final String? coverUrl;
  final ImageProvider? image;

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
      child: image == null && (url == null || url.isEmpty)
          ? fallback
          : Image(
              image:
                  image ??
                  ArtworkImage.forSize(
                    url!,
                    logicalEdge: size,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  ),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: image == null
                  ? null
                  : (context, child, frame, synchronous) {
                      if (frame == 0 && !synchronous) {
                        MotionSnapshot.invalidate(context);
                      }
                      return child;
                    },
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? _) =>
                      fallback,
            ),
    );
  }
}
