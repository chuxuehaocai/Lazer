import 'package:flutter/material.dart';

import '../data/models.dart';
import 'plate_art.dart';

/// A track change dissolves one cover into the next.
///
/// The old slide read as a carousel; a television at ten feet wants the calmer
/// Apple-style cross-fade: 420 ms, a symmetric ease-in-out, and only a hint of
/// scale so the artwork does not simply blink. Both children live in their own
/// repaint boundary, so the fade is a compositor operation on cached pixels
/// rather than a re-rasterisation of the artwork every frame.
///
/// Metadata refreshes keep the same [ValueKey] and do not replay the dissolve;
/// [direction] is retained for callers that still report the queue direction,
/// but the transition itself is direction-free.
class AnimatedTrackCover extends StatelessWidget {
  const AnimatedTrackCover({
    super.key,
    required this.track,
    required this.direction,
    this.size = 480,
  });

  final Track track;
  final int direction;
  final double size;

  static const Curve _dissolve = Cubic(0.4, 0.0, 0.2, 1.0);

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: _dissolve,
      switchOutCurve: _dissolve,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 1.012, end: 1).animate(animation),
            child: RepaintBoundary(child: child),
          ),
        );
      },
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (previous.isNotEmpty)
            ExcludeSemantics(child: IgnorePointer(child: previous.last)),
          ?current,
        ],
      ),
      child: PlateArt(
        key: ValueKey<String>(track.id),
        seed: track.coverSeed,
        coverUrl: track.coverUrl,
        radius: BorderRadius.zero,
        size: size,
      ),
    ),
  );
}
