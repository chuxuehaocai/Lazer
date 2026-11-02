import 'package:flutter/material.dart';

import 'motion_snapshot.dart';

abstract final class ViewMotion {
  static const curve = Cubic(.22, 1, .36, 1);
  static const duration = Duration(milliseconds: 320);
}

/// Small compositor-only movement shared by forms, tabs and embedded views.
class ViewTransitionSwitcher extends StatelessWidget {
  const ViewTransitionSwitcher({
    super.key,
    required this.child,
    this.expand = true,
  });
  final Widget child;
  final bool expand;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : ViewMotion.duration,
    switchInCurve: ViewMotion.curve,
    switchOutCurve: ViewMotion.curve.flipped,
    layoutBuilder: (current, previous) => Stack(
      fit: expand ? StackFit.expand : StackFit.loose,
      alignment: Alignment.topCenter,
      children: [
        if (previous.isNotEmpty)
          ExcludeFocus(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: TickerMode(enabled: false, child: previous.last),
              ),
            ),
          ),
        ?current,
      ],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .025),
          end: Offset.zero,
        ).animate(animation),
        child: MotionSnapshot(animation: animation, child: child),
      ),
    ),
    child: child,
  );
}

class LazerPageTransitionsBuilder extends PageTransitionsBuilder {
  const LazerPageTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return _RouteTransition(animation: animation, child: child);
  }
}

/// A reverse starts at the currently painted position, including when Back
/// interrupts an entrance. Merely swapping ease-out for its flipped curve at
/// that point would move the page before the reverse has even taken a frame.
class _RouteTransition extends StatefulWidget {
  const _RouteTransition({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  State<_RouteTransition> createState() => _RouteTransitionState();
}

class _RouteTransitionState extends State<_RouteTransition> {
  late _RouteSegment _segment;
  late Animation<double> _motion;

  void _attach() {
    _segment = _RouteSegment(
      forward: widget.animation.status != AnimationStatus.reverse,
    );
    _motion = widget.animation.drive(_segment);
    widget.animation.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      _segment.retarget(
        widget.animation.value,
        forward: status == AnimationStatus.forward,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(_RouteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      _attach();
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _motion,
    child: SlideTransition(
      position: _motion.drive(
        Tween<Offset>(begin: const Offset(.035, 0), end: Offset.zero),
      ),
      child: MotionSnapshot(animation: widget.animation, child: widget.child),
    ),
  );
}

class _RouteSegment extends Animatable<double> {
  _RouteSegment({required bool forward})
    : _start = forward ? 0 : 1,
      _startValue = forward ? 0 : 1,
      _end = forward ? 1 : 0;

  double _start;
  double _startValue;
  double _end;

  void retarget(double progress, {required bool forward}) {
    final end = forward ? 1.0 : 0.0;
    if (_end == end) return;
    _startValue = transform(progress);
    _start = progress;
    _end = end;
  }

  @override
  double transform(double t) {
    if (_start == _end) return _end;
    final fraction = ((t - _start) / (_end - _start)).clamp(0.0, 1.0);
    return _startValue +
        (_end - _startValue) * ViewMotion.curve.transform(fraction);
  }
}
