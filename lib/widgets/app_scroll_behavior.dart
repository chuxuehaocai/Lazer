import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import '../scrolling/scroll_motion.dart';

/// Shared momentum and acceleration for touch flings and mouse wheels.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior({
    this.retention = ScrollMotion.defaultRetention,
    this.acceleration = ScrollMotion.defaultAcceleration,
  });
  final double retention;
  final double acceleration;
  @override
  bool shouldNotify(covariant AppScrollBehavior oldDelegate) =>
      oldDelegate.retention != retention ||
      oldDelegate.acceleration != acceleration;
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => _WheelMomentum(
    details: details,
    retention: retention,
    acceleration: acceleration,
    smoothDiscreteWheel:
        getPlatform(context) == TargetPlatform.windows ||
        getPlatform(context) == TargetPlatform.linux,
    child: child,
  );
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    final platform = getPlatform(context);
    if ((platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) &&
        ScrollMotion.isNative(
          retention: retention,
          acceleration: acceleration,
        )) {
      return const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      );
    }
    return InertiaScrollPhysics(
      retention: retention,
      acceleration: acceleration,
    );
  }
}

class InertiaScrollPhysics extends ClampingScrollPhysics {
  const InertiaScrollPhysics({
    required this.retention,
    this.acceleration = ScrollMotion.defaultAcceleration,
    super.parent,
  });
  final double retention;
  final double acceleration;
  @override
  InertiaScrollPhysics applyTo(ScrollPhysics? ancestor) => InertiaScrollPhysics(
    retention: retention,
    acceleration: acceleration,
    parent: buildParent(ancestor),
  );
  @override
  double carriedMomentum(double existingVelocity) =>
      ScrollMotion.carriedVelocity(
        existingVelocity,
        retention: retention,
        acceleration: acceleration,
      );
  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    if (velocity.abs() < tolerance.velocity ||
        (velocity < 0 && position.pixels <= position.minScrollExtent) ||
        (velocity > 0 && position.pixels >= position.maxScrollExtent)) {
      return null;
    }
    // At the defaults the settings must reproduce Flutter's stock scrolling,
    // so hand the fling to the framework's own clamping simulation instead of
    // approximating it with a tuned friction curve.
    if (ScrollMotion.isNative(
      retention: retention,
      acceleration: acceleration,
    )) {
      return ClampingScrollSimulation(
        position: position.pixels,
        velocity: velocity,
        tolerance: tolerance,
      );
    }
    return FrictionSimulation(
      math.pow(retention, 60).toDouble(),
      position.pixels,
      velocity,
      tolerance: tolerance,
    );
  }
}

/// The active scroll behavior with mouse dragging enabled.
///
/// Material accepts touch-like pointers on Android and iOS, so a phone-sized
/// emulator, a tablet with a mouse or a head unit can tap a card but cannot
/// drag a horizontal shelf. The shelf has no competing mouse gesture, and the
/// rest of the behavior (wheel momentum, physics) stays as configured.
ScrollBehavior shelfScrollBehavior(BuildContext context) {
  final ScrollBehavior behavior = ScrollConfiguration.of(context);
  return behavior.copyWith(
    dragDevices: <PointerDeviceKind>{
      ...behavior.dragDevices,
      PointerDeviceKind.mouse,
    },
  );
}

class _WheelMomentum extends StatefulWidget {
  const _WheelMomentum({
    required this.details,
    required this.retention,
    required this.acceleration,
    required this.smoothDiscreteWheel,
    required this.child,
  });
  final ScrollableDetails details;
  final double retention;
  final double acceleration;
  final bool smoothDiscreteWheel;
  final Widget child;
  @override
  State<_WheelMomentum> createState() => _WheelMomentumState();
}

class _WheelMomentumState extends State<_WheelMomentum>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _velocity = 0;
  Duration _last = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ticker ??= createTicker(_tick);
  }

  ScrollPosition? get _position {
    final controller = widget.details.controller;
    return controller != null && controller.positions.length == 1
        ? controller.position
        : null;
  }

  void _stop() {
    _ticker?.stop();
    _velocity = 0;
    _last = Duration.zero;
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final position = _position;
    if (position == null || _velocity.abs() < 5) {
      _stop();
      return;
    }
    if (dt <= 0 || dt > 0.1) return;
    final native = ScrollMotion.isNative(
      retention: widget.retention,
      acceleration: widget.acceleration,
    );
    final double decay = -math.log(native ? .95 : widget.retention) * 60;
    final double factor = math.exp(-decay * dt);
    final next = (position.pixels + _velocity * (1 - factor) / decay).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) {
      _stop();
      return;
    }
    position.jumpTo(next);
    _velocity *= factor;
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Stock Flutter applies a wheel step synchronously with no momentum. The
    // default settings must feel exactly like that, so leave the signal alone
    // until the inertia sliders are actually moved.
    if (ScrollMotion.isNative(
          retention: widget.retention,
          acceleration: widget.acceleration,
        ) &&
        !widget.smoothDiscreteWheel) {
      return;
    }
    final position = _position;
    if (position == null ||
        !position.physics.shouldAcceptUserOffset(position)) {
      return;
    }
    final horizontal =
        axisDirectionToAxis(widget.details.direction) == Axis.horizontal;
    var delta = horizontal ? event.scrollDelta.dx : event.scrollDelta.dy;
    // High-resolution trackpad deltas already carry operating-system momentum.
    if (widget.smoothDiscreteWheel && delta.abs() < 18) return;
    if (widget.details.direction == AxisDirection.up ||
        widget.details.direction == AxisDirection.left) {
      delta = -delta;
    }
    final bounded = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (delta == 0 || bounded == position.pixels) return;
    final before = position.pixels;
    // Scrollable claims the signal before its chrome receives it. Replace
    // that synchronous step before the next painted frame, only if this
    // viewport actually consumed it (nested scroll views remain independent).
    scheduleMicrotask(() {
      if (!mounted || _position != position || position.pixels == before) {
        return;
      }
      final consumed = position.pixels - before;
      position.jumpTo(before);
      _velocity = ScrollMotion.addWheelImpulse(
        _velocity,
        consumed,
        acceleration: widget.acceleration,
      );
      final ticker = _ticker;
      if (ticker != null && !ticker.isActive) {
        _last = Duration.zero;
        ticker.start();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: _wheel,
    onPointerDown: (_) => _stop(),
    child: widget.child,
  );
}
