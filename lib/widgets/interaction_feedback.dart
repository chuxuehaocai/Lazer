import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;

import '../animation/apple_spring.dart';
import '../state/app_state.dart';

/// Supplies feedback preferences without listening to raw pointer events.
class InteractionFeedback extends InheritedWidget {
  const InteractionFeedback({
    super.key,
    required this.state,
    required super.child,
  });
  final AppState state;
  static AppState? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<InteractionFeedback>()?.state;
  @override
  bool updateShouldNotify(InteractionFeedback oldWidget) =>
      oldWidget.state != state;
}

VoidCallback? feedbackAction(BuildContext context, VoidCallback? action) {
  if (action == null) return null;
  return () {
    final state = InteractionFeedback.of(context);
    if (state != null) unawaited(state.feedback());
    action();
  };
}

/// Spring feedback driven by the control's own gesture and keyboard state.
/// No extra recognizer is added, so a scroll cancellation, disabled control,
/// focus action or semantic activation keeps the underlying Material behavior.
class SpringPress extends StatefulWidget {
  const SpringPress({super.key, required this.builder, this.pressedScale = .97})
    : assert(pressedScale > 0 && pressedScale <= 1);

  final Widget Function(BuildContext context, WidgetStatesController states)
  builder;
  final double pressedScale;

  @override
  State<SpringPress> createState() => _SpringPressState();
}

class _SpringPressState extends State<SpringPress>
    with SingleTickerProviderStateMixin {
  final WidgetStatesController _states = WidgetStatesController();
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  bool _reduceMotion = false;
  bool _pressed = false;
  bool _retargetScheduled = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _press.value = 0;
  }

  void _changed() {
    final bool pressed =
        _states.value.contains(WidgetState.pressed) &&
        !_states.value.contains(WidgetState.disabled);
    if (pressed == _pressed) return;
    _pressed = pressed;
    // Material may update disabled/selected state while it builds. Defer a
    // retarget from that phase so no ancestor is dirtied during child build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_retargetScheduled) return;
      _retargetScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _retargetScheduled = false;
        if (mounted) _retarget();
      });
      return;
    }
    _retarget();
  }

  void _retarget() {
    _press.springTo(
      _reduceMotion || !_pressed ? 0 : 1,
      spring: AppleSpring.responsive,
      reduceMotion: _reduceMotion,
    );
  }

  @override
  void dispose() {
    _states.removeListener(_changed);
    _states.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _press,
    child: widget.builder(context, _states),
    builder: (context, child) => Transform.scale(
      scale: 1 - (1 - widget.pressedScale) * _press.value,
      // Keep the original target reachable throughout the visual compression.
      transformHitTests: false,
      child: child,
    ),
  );
}
