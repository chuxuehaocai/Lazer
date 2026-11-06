import '../state/build_safe_notifier.dart';
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../animation/apple_spring.dart';

/// Interactive platform back for navigation that lives inside a route.
///
/// Android sends its actual system gesture progress. iOS owns its leading
/// screen edge in Flutter, just as CupertinoPageRoute does. Navigation changes
/// only after a committed gesture finishes; cancellation leaves it untouched.
class SystemBackGesture extends StatefulWidget {
  const SystemBackGesture({
    super.key,
    required this.canStart,
    required this.progress,
    required this.onStart,
    required this.onCommit,
    required this.child,
  });

  final bool Function() canStart;
  final ValueNotifier<double?> progress;
  final VoidCallback onStart;
  final VoidCallback onCommit;
  final Widget child;

  @override
  State<SystemBackGesture> createState() => _SystemBackGestureState();
}

class _SystemBackGestureState extends State<SystemBackGesture>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..addListener(_report);
  bool _active = false;
  bool _settling = false;
  double _origin = 0;
  double _width = 1;
  double _direction = 1;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _motion;
    WidgetsBinding.instance.addObserver(this);
  }

  void _report() {
    if (_active) widget.progress.value = _motion.value;
  }

  bool _start() {
    if (_active || !widget.canStart()) return false;
    _generation++;
    _active = true;
    _settling = false;
    _motion.value = 0;
    widget.onStart();
    widget.progress.value = 0;
    return true;
  }

  Future<void> _finish(bool commit, {double velocity = 0}) async {
    if (!_active || _settling) return;
    _settling = true;
    final generation = ++_generation;
    try {
      await _motion
          .springTo(
            commit ? 1 : 0,
            velocity: velocity,
            reduceMotion: MediaQuery.disableAnimationsOf(context),
          )
          .orCancel;
      if (!mounted || generation != _generation) return;
      if (commit) widget.onCommit();
    } on TickerCanceled {
      // Removing the host cancels the in-flight continuation.
    } finally {
      if (mounted && generation == _generation) {
        _active = false;
        _settling = false;
        widget.progress.value = null;
      }
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (Theme.of(context).platform != TargetPlatform.android ||
        backEvent.isButtonEvent ||
        !_start()) {
      return false;
    }
    _motion.value = backEvent.progress;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_active && !_settling) _motion.value = backEvent.progress;
  }

  @override
  void handleCancelBackGesture() => unawaited(_finish(false));

  @override
  void handleCommitBackGesture() => unawaited(_finish(true));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final rtl = Directionality.of(context) == TextDirection.rtl;
      return RawGestureDetector(
        excludeFromSemantics: true,
        behavior: HitTestBehavior.translucent,
        gestures: {
          _SystemEdgeRecognizer:
              GestureRecognizerFactoryWithHandlers<_SystemEdgeRecognizer>(
                () => _SystemEdgeRecognizer(),
                (recognizer) {
                  recognizer.width = box.maxWidth;
                  recognizer.leadingInset = rtl
                      ? MediaQuery.paddingOf(context).right
                      : MediaQuery.paddingOf(context).left;
                  recognizer.direction = rtl ? -1 : 1;
                  recognizer.canStart = () =>
                      Theme.of(context).platform == TargetPlatform.iOS &&
                      !_active &&
                      widget.canStart();
                  recognizer.onDown = (details) {
                    _origin = details.globalPosition.dx;
                    _width = box.maxWidth;
                    _direction = rtl ? -1 : 1;
                  };
                  recognizer.onStart = (details) {
                    if (_start()) {
                      _motion.value =
                          ((details.globalPosition.dx - _origin) *
                                  _direction /
                                  _width)
                              .clamp(0.0, 1.0);
                    }
                  };
                  recognizer.onUpdate = (details) {
                    if (_active && !_settling) {
                      _motion.value =
                          ((details.globalPosition.dx - _origin) *
                                  _direction /
                                  _width)
                              .clamp(0.0, 1.0);
                    }
                  };
                  recognizer.onEnd = (details) {
                    final velocity =
                        details.velocity.pixelsPerSecond.dx * _direction;
                    final commit = velocity < -700
                        ? false
                        : velocity > 700 || _motion.value > .5;
                    unawaited(_finish(commit, velocity: velocity / _width));
                  };
                  recognizer.onCancel = () => unawaited(_finish(false));
                  recognizer.onPointerCancelled = () =>
                      unawaited(_finish(false));
                },
              ),
        },
        child: widget.child,
      );
    },
  );
}

class _SystemEdgeRecognizer extends HorizontalDragGestureRecognizer {
  double width = 0, direction = 1, leadingInset = 0;
  bool Function()? canStart;
  VoidCallback? onPointerCancelled;

  @override
  bool isPointerAllowed(PointerEvent event) {
    final distance = direction > 0
        ? event.localPosition.dx
        : width - event.localPosition.dx;
    return distance >= 0 &&
        distance <= 24 + leadingInset &&
        (canStart?.call() ?? false) &&
        super.isPointerAllowed(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancelled?.call();
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind kind,
    double? slop,
  ) => globalDistanceMoved * direction > computeHitSlop(kind, gestureSettings);
}

/// Keeps platform back available when accessibility disables page motion.
class ReducedMotionBackGesture extends StatefulWidget {
  const ReducedMotionBackGesture({
    super.key,
    required this.route,
    required this.child,
  });
  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<ReducedMotionBackGesture> createState() =>
      _ReducedMotionBackGestureState();
}

class _ReducedMotionBackGestureState extends State<ReducedMotionBackGesture> {
  final ValueNotifier<double?> _progress = BuildSafeValueNotifier(null);
  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SystemBackGesture(
    canStart: () => widget.route.isCurrent && widget.route.popGestureEnabled,
    progress: _progress,
    onStart: () {},
    onCommit: () {
      if (widget.route.isCurrent &&
          widget.route.popDisposition == RoutePopDisposition.pop) {
        unawaited(widget.route.navigator!.maybePop());
      }
    },
    child: widget.child,
  );
}
