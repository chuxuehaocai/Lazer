import 'package:flutter/material.dart';

import '../navigation/pull_down_to_close.dart';
import '../state/app_state.dart';
import 'now_playing_page.dart';
import '../animation/motion_snapshot.dart';
import '../animation/view_transitions.dart';

/// Material open-upwards presentation: the player rises from the window
/// bottom to the top and reverses on close.
Future<void> openNowPlayingPage(BuildContext context, AppState state) {
  return Navigator.of(context).push<void>(NowPlayingRoute(state: state));
}

/// The player as a route.
///
/// The route doubles as the host of the player's pull-down dismissal: it hands
/// the drag its own transition animation, so a finger drag and the close
/// transition are one continuous motion.
class NowPlayingRoute extends PageRoute<void> implements PlayerPullDown {
  NowPlayingRoute({required this.state});

  final AppState state;
  final ValueNotifier<bool> _settled = ValueNotifier(false);

  @override
  void install() {
    super.install();
    animation!.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    _settled.value = status == AnimationStatus.completed;
  }

  @override
  void dispose() {
    animation?.removeStatusListener(_onStatus);
    _settled.dispose();
    super.dispose();
  }

  /// Time the pull takes to cover its whole travel when it settles.
  static const Duration _settleDuration = Duration(milliseconds: 260);

  /// Push and pop decelerate: fast on the way out of the tap, slow on arrival.
  static const Curve _transitionCurve = ViewMotion.curve;

  /// The controller is the actual visible openness, for both finger drags and
  /// timed transitions. Applying another curve in buildTransitions would jump
  /// a released pull and make a normal pop run the entrance backwards.
  @override
  Simulation createSimulation({required bool forward}) {
    final start = controller!.value;
    final duration =
        (forward ? transitionDuration : reverseTransitionDuration) *
        (forward ? 1 - start : start);
    return _PlayerRouteSimulation(
      start: start,
      end: forward ? 1 : 0,
      // Custom simulations bypass AnimationController's reduced-motion time
      // scaling. Preserve its normal behaviour so hidden transition semantics
      // and route disposal do not wait the full 300 ms on those systems.
      duration: WidgetsBinding.instance.disableAnimations
          ? duration * .05
          : duration,
    );
  }

  /// Whether a finger owns the transition right now.
  ///
  /// The drag writes [controller] directly, so the offset has to stay linear
  /// with the finger; only the push, the pop and the settle after a released
  /// pull are shaped by [_transitionCurve].
  bool _dragging = false;

  /// A pull may only begin once the route has finished presenting itself.
  @override
  bool get canStart =>
      isCurrent && animation?.status == AnimationStatus.completed;

  @override
  void startPull() {
    _dragging = true;
    _settled.value = false;
    controller?.stop();
  }

  @override
  void updatePull(double progress) {
    // Stay off the lower bound: popping, not dragging, finishes the dismissal.
    controller?.value = (1 - progress).clamp(.001, 1);
  }

  @override
  void endPull(double velocity) {
    _dragging = false;
    final double open = controller?.value ?? 1;
    final double pulled = 1 - open;
    final bool dismiss = velocity < -900
        ? false
        : (velocity > 900 && pulled > .02) || pulled >= .22;
    if (dismiss) {
      // Popping continues the route's own reverse transition from here.
      navigator?.pop();
      return;
    }
    controller?.animateTo(
      1,
      duration: Duration(
        milliseconds: (pulled * _settleDuration.inMilliseconds).round().clamp(
          80,
          260,
        ),
      ),
      curve: _transitionCurve,
    );
  }

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => ValueListenableBuilder<bool>(
    valueListenable: _settled,
    child: NowPlayingPage(
      state: state,
      pullDown: this,
      entranceSettled: _settled,
    ),
    builder: (context, settled, child) =>
        ExcludeSemantics(excluding: !settled, child: child),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    // Timed motion curves the controller itself. A drag and its released
    // continuation consequently share the exact same visible coordinate.
    return AnimatedBuilder(
      animation: animation,
      child: MotionSnapshot(animation: animation, child: child),
      builder: (BuildContext context, Widget? child) {
        final double travelled = animation.value;
        // The page is still mounted for the reverse transition. Pause its
        // ambient and lyric tickers so the compositor can move one stable
        // layer offscreen without also repainting the full player each frame.
        final bool tickersEnabled =
            !_dragging && animation.status == AnimationStatus.completed;
        return FractionalTranslation(
          translation: Offset(0, 1 - travelled),
          child: TickerMode(enabled: tickersEnabled, child: child!),
        );
      },
    );
  }
}

class _PlayerRouteSimulation extends Simulation {
  _PlayerRouteSimulation({
    required this.start,
    required this.end,
    required Duration duration,
  }) : seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;

  final double start;
  final double end;
  final double seconds;

  @override
  double x(double time) {
    if (seconds == 0 || time >= seconds) return end;
    final progress = (time / seconds).clamp(0.0, 1.0);
    return start + (end - start) * ViewMotion.curve.transform(progress);
  }

  @override
  double dx(double time) {
    if (seconds == 0 || time >= seconds) return 0;
    const delta = .00001;
    final before = (time - delta).clamp(0.0, seconds);
    final after = (time + delta).clamp(0.0, seconds);
    return (x(after) - x(before)) / (after - before);
  }

  @override
  bool isDone(double time) => time >= seconds;
}
