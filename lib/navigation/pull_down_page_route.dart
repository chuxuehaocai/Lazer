import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoFullscreenDialogTransition;

import '../animation/apple_spring.dart';

/// A vertical page transition with a platform-independent top-edge back drag.
/// The route animation exposes the actual previous page during the gesture.
class PullDownPageRoute<T> extends MaterialPageRoute<T> {
  PullDownPageRoute({required super.builder, super.settings});

  NavigatorState? _pullNavigator;
  bool _settling = false;
  bool _disposed = false;
  bool get _pulling => _pullNavigator != null;
  bool _dragging = false;
  double _initialOpen = 1;
  double _pullHeight = 1;
  int _settleGeneration = 0;

  @override
  Simulation createSimulation({required bool forward}) {
    final target = forward ? 1.0 : 0.0;
    final reduced =
        WidgetsBinding.instance.disableAnimations ||
        (navigator != null &&
            (MediaQuery.maybeDisableAnimationsOf(navigator!.context) ?? false));
    return AppleSpring.smooth.simulation(
      reduced ? target : controller!.value,
      target,
      velocity: reduced ? 0 : controller!.velocity,
    );
  }

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 340);

  bool get _canStartPull =>
      !_disposed &&
      !_dragging &&
      isCurrent &&
      isActive &&
      !isFirst &&
      !willHandlePopInternally &&
      popDisposition == RoutePopDisposition.pop &&
      (!(navigator?.userGestureInProgress ?? true) || _pulling);

  bool _startPull(double height) {
    if (!_canStartPull) return false;
    _settleGeneration++;
    _settling = false;
    _dragging = true;
    _initialOpen = controller!.value;
    _pullHeight = height;
    controller!.stop();
    if (!_pulling) {
      _pullNavigator = navigator;
      _pullNavigator!.didStartUserGesture();
    }
    return true;
  }

  void _updatePull(double progress) {
    if (_dragging && isCurrent) {
      // Keep the route alive even when the finger reaches the bottom edge.
      controller!.value = (_initialOpen - progress).clamp(.001, 1);
    }
  }

  Future<void> _settlePull({
    bool cancel = false,
    bool alreadyPopped = false,
    double velocity = 0,
    bool reduceMotion = false,
  }) async {
    if (!_pulling || _settling || _disposed) return;
    _dragging = false;
    _settling = true;
    final generation = ++_settleGeneration;
    final nav = _pullNavigator!;
    final progress = 1 - controller!.value;
    final wantsPop = velocity < -700
        ? false
        : velocity > 700 && progress > .025 || progress >= .28;
    final commit =
        alreadyPopped ||
        (!cancel &&
            wantsPop &&
            isCurrent &&
            !willHandlePopInternally &&
            popDisposition == RoutePopDisposition.pop);
    final leaving = commit || !isActive;
    try {
      if (commit && !alreadyPopped) {
        nav.pop();
        // Replace TransitionRoute's pop simulation before the next frame so
        // the page continues from the exact position where the finger left.
        controller!.stop(canceled: false);
      }
      await controller!
          .springTo(
            leaving ? 0 : 1,
            velocity: -velocity / _pullHeight,
            reduceMotion: reduceMotion,
          )
          .orCancel;
    } on TickerCanceled {
      // Removing the route or disposing its navigator cancels the settlement.
    } finally {
      if (generation == _settleGeneration) {
        _settling = false;
        _releasePull();
      }
    }
  }

  void _releasePull({bool defer = false}) {
    final nav = _pullNavigator;
    _pullNavigator = null;
    if (nav == null) return;
    void release() {
      if (nav.mounted && nav.userGestureInProgress) nav.didStopUserGesture();
    }

    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => release());
    } else {
      release();
    }
  }

  @override
  bool didPop(T? result) {
    final popped = super.didPop(result);
    if (popped && _pulling && !_settling) {
      unawaited(_settlePull(alreadyPopped: true));
    }
    return popped;
  }

  @override
  void dispose() {
    _disposed = true;
    _releasePull(defer: true);
    super.dispose();
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final platform = Theme.of(context).platform;
    final isMobilePlatform =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final page = AnimatedBuilder(
      animation: Listenable.merge([
        animation,
        navigator!.userGestureInProgressNotifier,
      ]),
      child: child,
      builder: (context, child) {
        final systemBack = popGestureInProgress && !_pulling;
        if (systemBack && platform == TargetPlatform.iOS) {
          return CupertinoFullscreenDialogTransition(
            primaryRouteAnimation: animation,
            secondaryRouteAnimation: secondaryAnimation,
            linearTransition: true,
            child: child!,
          );
        }
        final progress = animation.value;
        return SlideTransition(
          key: const ValueKey('now-playing-page-transition'),
          position: AlwaysStoppedAnimation(
            Offset(0, systemBack ? 0 : 1 - progress),
          ),
          child: child,
        );
      },
    );
    final interactive = AnimatedBuilder(
      animation: animation,
      child: page,
      builder: (context, child) => LayoutBuilder(
        builder: (context, box) => _TopEdgeBackGesture(
          enabled: isMobilePlatform || box.maxWidth < 720,
          // The visible page edge moves down with an interrupted transition.
          // Expand the hit strip by that same amount so the user can grab it
          // again without waiting for the spring to finish.
          activationHeight:
              MediaQuery.paddingOf(context).top +
              64 +
              (1 - animation.value).clamp(0.0, 1.0) * box.maxHeight,
          height: box.maxHeight,
          canStart: () => _canStartPull,
          onStart: () => _startPull(box.maxHeight),
          onUpdate: _updatePull,
          onEnd: (velocity, cancel) => unawaited(
            _settlePull(
              velocity: velocity,
              cancel: cancel,
              reduceMotion: MediaQuery.disableAnimationsOf(context),
            ),
          ),
          child: child!,
        ),
      ),
    );
    if (platform != TargetPlatform.android) return interactive;
    // Android's system edge back remains available alongside the app gesture.
    return const PredictiveBackFullscreenPageTransitionsBuilder()
        .buildTransitions(
          this,
          context,
          popGestureInProgress && !_pulling
              ? animation
              : const AlwaysStoppedAnimation(1),
          secondaryAnimation,
          interactive,
        );
  }
}

class _TopEdgeBackGesture extends StatefulWidget {
  const _TopEdgeBackGesture({
    required this.enabled,
    required this.activationHeight,
    required this.height,
    required this.canStart,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.child,
  });
  final bool enabled;
  final double activationHeight, height;
  final bool Function() canStart, onStart;
  final ValueChanged<double> onUpdate;
  final void Function(double velocity, bool cancel) onEnd;
  final Widget child;
  @override
  State<_TopEdgeBackGesture> createState() => _TopEdgeBackGestureState();
}

class _TopEdgeBackGestureState extends State<_TopEdgeBackGesture> {
  bool _started = false;
  double _origin = 0, _distance = 0, _height = 1;

  void _start(DragStartDetails details) {
    if (!widget.onStart()) return;
    _started = true;
    _height = widget.height;
    _distance = details.globalPosition.dy - _origin;
    widget.onUpdate(_distance / _height);
  }

  void _update(DragUpdateDetails details) {
    if (!_started) return;
    _distance = (details.globalPosition.dy - _origin).clamp(-_height, _height);
    widget.onUpdate(_distance / _height);
  }

  void _end(double velocity, {bool cancel = false}) {
    if (!_started) return;
    _started = false;
    widget.onEnd(velocity, cancel);
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.translucent,
    excludeFromSemantics: true,
    gestures: {
      _TopEdgeDragRecognizer:
          GestureRecognizerFactoryWithHandlers<_TopEdgeDragRecognizer>(
            () => _TopEdgeDragRecognizer(debugOwner: this),
            (recognizer) {
              recognizer.canStart = () =>
                  widget.enabled && widget.height > 0 && widget.canStart();
              recognizer.activationHeight = widget.activationHeight;
              recognizer.onDown = (details) {
                _origin = details.globalPosition.dy;
              };
              recognizer.onStart = _start;
              recognizer.onUpdate = _update;
              recognizer.onEnd = (details) =>
                  _end(details.velocity.pixelsPerSecond.dy);
              recognizer.onCancel = () => _end(0, cancel: true);
              recognizer.onPointerCancelled = () => _end(0, cancel: true);
            },
          ),
    },
    child: widget.child,
  );
}

class _TopEdgeDragRecognizer extends VerticalDragGestureRecognizer {
  _TopEdgeDragRecognizer({super.debugOwner});
  double activationHeight = 0;
  bool Function()? canStart;
  VoidCallback? onPointerCancelled;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancelled?.call();
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved > computeHitSlop(pointerDeviceKind, gestureSettings);

  @override
  bool isPointerAllowed(PointerEvent event) {
    return event is PointerDownEvent &&
        event.localPosition.dy >= 0 &&
        event.localPosition.dy <= activationHeight &&
        (canStart?.call() ?? false) &&
        super.isPointerAllowed(event);
  }
}
