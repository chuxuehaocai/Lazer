import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../widgets/retained_content_switcher.dart';
import 'apple_spring.dart';
import 'motion_snapshot.dart';

abstract final class ViewMotion {
  static const curve = AppleSpringCurve();
  static const duration = Duration(milliseconds: 320);
}

/// Small compositor-only movement shared by forms, tabs and embedded views.
class ViewTransitionSwitcher extends StatefulWidget {
  const ViewTransitionSwitcher({
    super.key,
    required this.child,
    this.expand = true,
  });
  final Widget child;
  final bool expand;

  @override
  State<ViewTransitionSwitcher> createState() => _ViewTransitionSwitcherState();
}

class _ViewTransitionSwitcherState extends State<ViewTransitionSwitcher> {
  final Map<(Type, Key?), String> _identities = {};
  var _serial = 0;

  (Type, Key?) get _identity => (widget.child.runtimeType, widget.child.key);

  @override
  Widget build(BuildContext context) => RetainedContentSwitcher(
    currentKey: _identities.putIfAbsent(_identity, () => 'view-${_serial++}'),
    page: widget.child,
    retainKeys: const {},
    duration: ViewMotion.duration,
    expand: widget.expand,
    slideFraction: .025,
    onTransitionChanged: (moving) {
      if (!moving) {
        _identities.removeWhere((identity, _) => identity != _identity);
      }
    },
  );
}

/// Shared navigation physics on every host. The controller is the presented
/// coordinate, so reversing a push or releasing a drag preserves momentum.
class ApplePageRoute<T> extends MaterialPageRoute<T> {
  ApplePageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
  });

  NavigatorState? _gestureNavigator;
  bool _dragging = false;
  bool _disposed = false;
  int _generation = 0;
  double _initial = 1;
  double _width = 1;
  double? _releaseVelocity;

  bool get _reduced =>
      WidgetsBinding.instance.disableAnimations ||
      (navigator != null &&
          (MediaQuery.maybeDisableAnimationsOf(navigator!.context) ?? false));

  @override
  Simulation createSimulation({required bool forward}) {
    final target = forward ? 1.0 : 0.0;
    final velocity = _releaseVelocity ?? controller!.velocity;
    _releaseVelocity = null;
    return AppleSpring.smooth.simulation(
      _reduced ? target : controller!.value,
      target,
      velocity: _reduced ? 0 : velocity,
    );
  }

  bool get _canDrag =>
      !_disposed &&
      !_dragging &&
      isCurrent &&
      isActive &&
      !isFirst &&
      !willHandlePopInternally &&
      popDisposition == RoutePopDisposition.pop &&
      (controller?.value ?? 0) > .001 &&
      (!(navigator?.userGestureInProgress ?? true) ||
          _gestureNavigator != null);

  void _start(double width) {
    _generation++;
    _dragging = true;
    _initial = controller!.value;
    _width = width;
    controller!.stop();
    if (_gestureNavigator == null) {
      _gestureNavigator = navigator;
      _gestureNavigator!.didStartUserGesture();
    }
  }

  void _update(double fraction) {
    if (_dragging) controller!.value = (_initial - fraction).clamp(.001, 1);
  }

  Future<void> _finish(double velocity, {bool cancel = false}) async {
    if (!_dragging || _disposed) return;
    _dragging = false;
    final generation = ++_generation;
    final dismiss =
        !cancel &&
        _canDrag &&
        (velocity < -700 ? false : velocity > 700 || controller!.value < .65);
    final normalizedVelocity = cancel ? 0.0 : -velocity / _width;
    try {
      if (dismiss) {
        _releaseVelocity = normalizedVelocity;
        navigator!.pop();
      }
      await controller!
          .springTo(
            dismiss || !isActive ? 0 : 1,
            velocity: normalizedVelocity,
            reduceMotion: _reduced,
          )
          .orCancel;
    } on TickerCanceled {
      // Another drag, route removal or navigator disposal owns the next move.
    } finally {
      if (generation == _generation) _releaseGesture();
    }
  }

  void _releaseGesture() {
    final nav = _gestureNavigator;
    _gestureNavigator = null;
    if (nav?.mounted == true && nav!.userGestureInProgress) {
      nav.didStopUserGesture();
    }
  }

  @override
  bool didPop(T? result) {
    final popped = super.didPop(result);
    if (popped && _dragging) {
      _dragging = false;
      _generation++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _releaseGesture());
    }
    return popped;
  }

  @override
  void dispose() {
    _disposed = true;
    final nav = _gestureNavigator;
    _gestureNavigator = null;
    if (nav != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (nav.mounted && nav.userGestureInProgress) nav.didStopUserGesture();
      });
    }
    super.dispose();
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return LayoutBuilder(
      builder: (context, box) => _PageEdgeGesture(
        route: this,
        width: box.maxWidth,
        child: _SpringPageSurface(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          child: child,
        ),
      ),
    );
  }
}

class _PageEdgeGesture extends StatefulWidget {
  const _PageEdgeGesture({
    required this.route,
    required this.width,
    required this.child,
  });
  final ApplePageRoute<dynamic> route;
  final double width;
  final Widget child;
  @override
  State<_PageEdgeGesture> createState() => _PageEdgeGestureState();
}

class _PageEdgeGestureState extends State<_PageEdgeGesture> {
  double _origin = 0;
  double _dragWidth = 1;
  double _dragDirection = 1;
  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context) == TextDirection.rtl
        ? -1.0
        : 1.0;
    return RawGestureDetector(
      excludeFromSemantics: true,
      gestures: {
        _PageEdgeRecognizer:
            GestureRecognizerFactoryWithHandlers<_PageEdgeRecognizer>(
              () => _PageEdgeRecognizer(),
              (recognizer) {
                recognizer.direction = direction;
                recognizer.width = widget.width;
                recognizer.openness = () => widget.route.animation?.value ?? 1;
                recognizer.canStart = () => widget.route._canDrag;
                recognizer.onDown = (details) {
                  _origin = details.globalPosition.dx;
                  _dragWidth = widget.width;
                  _dragDirection = direction;
                };
                recognizer.onStart = (details) {
                  widget.route._start(_dragWidth);
                  widget.route._update(
                    (details.globalPosition.dx - _origin) *
                        _dragDirection /
                        _dragWidth,
                  );
                };
                recognizer.onUpdate = (details) => widget.route._update(
                  (details.globalPosition.dx - _origin) *
                      _dragDirection /
                      _dragWidth,
                );
                recognizer.onEnd = (details) => widget.route._finish(
                  details.velocity.pixelsPerSecond.dx * _dragDirection,
                );
                recognizer.onCancel = () =>
                    widget.route._finish(0, cancel: true);
                recognizer.onPointerCancelled = () =>
                    widget.route._finish(0, cancel: true);
              },
            ),
      },
      child: widget.child,
    );
  }
}

class _PageEdgeRecognizer extends HorizontalDragGestureRecognizer {
  double direction = 1;
  double width = 1;
  double Function()? openness;
  bool Function()? canStart;
  VoidCallback? onPointerCancelled;

  @override
  void handleEvent(PointerEvent event) {
    // DragGestureRecognizer calls onEnd even for an accepted pointer cancel.
    // Resolve cancellation before that synthesized end can commit a pop.
    if (event is PointerCancelEvent) onPointerCancelled?.call();
    super.handleEvent(event);
  }

  @override
  bool isPointerAllowed(PointerEvent event) {
    final open = (openness?.call() ?? 1).clamp(0.0, 1.0);
    final distance = direction > 0
        ? event.localPosition.dx - width * (1 - open)
        : width * open - event.localPosition.dx;
    return distance >= 0 &&
        distance <= 24 &&
        (canStart?.call() ?? false) &&
        super.isPointerAllowed(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind kind,
    double? slop,
  ) => globalDistanceMoved * direction > computeHitSlop(kind, gestureSettings);
}

class _SpringPageSurface extends StatelessWidget {
  const _SpringPageSurface({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });
  final Animation<double> animation, secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) => SlideTransition(
    position: Tween(
      begin: Offset.zero,
      end: const Offset(-.3, 0),
    ).animate(secondaryAnimation),
    textDirection: Directionality.of(context),
    child: SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(animation),
      textDirection: Directionality.of(context),
      child: MotionSnapshot(animation: animation, child: child),
    ),
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
