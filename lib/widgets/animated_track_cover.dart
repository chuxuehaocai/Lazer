import 'package:flutter/material.dart';

import '../data/models.dart';
import 'plate_art.dart';

/// A track change dissolves one cover into the next over 420 ms with a soft
/// ease-in-out. Incoming artwork is opaque below
/// the fading previous artwork, so the middle of a dissolve never reveals the
/// background or darkens. Each cover lives in its own repaint boundary,
/// so the fade is a compositor operation on cached pixels
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
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 420),
      switchInCurve: _dissolve,
      switchOutCurve: _dissolve,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return _CoverDissolve(animation: animation, child: child);
      },
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ?current,
          // Keep the old composition above a new plate, including when a
          // second track arrives before the first dissolve has finished.
          for (final outgoing in previous.reversed)
            ExcludeSemantics(
              key: outgoing.key,
              child: IgnorePointer(child: outgoing),
            ),
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

class _CoverDissolve extends StatefulWidget {
  const _CoverDissolve({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  State<_CoverDissolve> createState() => _CoverDissolveState();
}

class _CoverDissolveState extends State<_CoverDissolve> {
  late _CoverOpacity _opacity;

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      // An interrupted entrance may reverse from a value below one. Its
      // visible plate was opaque, so its exit must still start opaque.
      _opacity.exitStart = widget.animation.value;
    }
  }

  void _attach() {
    _opacity = _CoverOpacity(widget.animation);
    widget.animation.addStatusListener(_status);
    _status(widget.animation.status);
  }

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(_CoverDissolve oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_status);
      _attach();
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: RepaintBoundary(child: widget.child),
  );
}

class _CoverOpacity extends Animation<double>
    with AnimationWithParentMixin<double> {
  _CoverOpacity(this.parent);
  @override
  final Animation<double> parent;
  double exitStart = 1;

  @override
  double get value => switch (parent.status) {
    AnimationStatus.reverse =>
      exitStart > 0 ? (parent.value / exitStart).clamp(0.0, 1.0) : 0,
    AnimationStatus.dismissed => 0,
    _ => 1,
  };
}
