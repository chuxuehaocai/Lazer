import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Fade the filtered result, including its blur halo, before clipping it.
/// Horizontal gutters leave room for the first/last glyph's Gaussian tail.
class LyricEdgeFade extends StatelessWidget {
  const LyricEdgeFade({
    super.key,
    required this.child,
    required this.verticalExtent,
    this.horizontal = true,
  });

  static const horizontalExtent = 18.0;
  final Widget child;
  final double verticalExtent;

  /// Fades the left/right edges as well.
  ///
  /// Each mask is a full-pane offscreen pass. A wide lyric canvas already
  /// reserves an 18 px gutter for the blur halo, so the viewport only keeps
  /// this second pass on compact layouts where a wrapped line can come close
  /// to the edge.
  final bool horizontal;

  ui.Shader _shader(Rect bounds, {required bool vertical}) {
    final length = vertical ? bounds.height : bounds.width;
    final extent = vertical ? verticalExtent : horizontalExtent;
    final fraction = length <= 0 ? 0.0 : math.min(0.24, extent / length);
    if (fraction <= 0.001) {
      return ui.Gradient.linear(
        vertical ? bounds.topCenter : bounds.centerLeft,
        vertical ? bounds.bottomCenter : bounds.centerRight,
        const [ui.Color(0xFFFFFFFF), ui.Color(0xFFFFFFFF)],
        const [0.0, 1.0],
      );
    }
    // Smoothstep samples avoid a visible change in slope where the fade begins.
    const levels = [0, 11, 40, 81, 128, 174, 215, 244, 255];
    final colors = [
      for (final alpha in levels) ui.Color.fromARGB(alpha, 255, 255, 255),
      for (final alpha in levels.reversed)
        ui.Color.fromARGB(alpha, 255, 255, 255),
    ];
    final stops = [
      for (var i = 0; i < levels.length; i++)
        (fraction * i / (levels.length - 1)).clamp(0.0, 1.0),
      for (var i = 0; i < levels.length; i++)
        (1 - fraction + fraction * i / (levels.length - 1)).clamp(0.0, 1.0),
    ];
    return ui.Gradient.linear(
      vertical ? bounds.topCenter : bounds.centerLeft,
      vertical ? bounds.bottomCenter : bounds.centerRight,
      colors,
      stops,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget masked = child;
    if (horizontal) {
      masked = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => _shader(bounds, vertical: false),
        child: masked,
      );
    }
    return ClipRect(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => _shader(bounds, vertical: true),
        child: masked,
      ),
    );
  }
}
