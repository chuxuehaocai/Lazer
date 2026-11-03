import 'package:flutter/material.dart';

import '../navigation/pull_down_to_close.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import 'now_playing_page.dart';
import 'player_page_motion.dart';
import '../animation/motion_snapshot.dart';

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
  AnimationController createAnimationController() =>
      AnimationController.unbounded(
        vsync: navigator!,
        duration: transitionDuration,
        reverseDuration: reverseTransitionDuration,
        debugLabel: debugLabel,
      );

  // The navigator's fades and secondary routes require normalized progress.
  // The player paints the physical controller so its rebound stays visible.
  @override
  Animation<double> createAnimation() =>
      controller!.drive(_ClampedPlayerProgress());

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

  double? _releaseVelocity;
  double _initialOpen = 1;

  bool get _reduceMotion =>
      WidgetsBinding.instance.disableAnimations ||
      (navigator != null &&
          (MediaQuery.maybeDisableAnimationsOf(navigator!.context) ?? false));

  bool get _compact =>
      navigator == null ||
      useCompactLayout(
        state.uiMode,
        MediaQuery.sizeOf(navigator!.context).width,
      );

  /// The controller is the actual visible openness, for both finger drags and
  /// timed transitions. Applying another curve in buildTransitions would jump
  /// a released pull and make a normal pop run the entrance backwards.
  @override
  Simulation createSimulation({required bool forward}) {
    final target = forward ? 1.0 : 0.0;
    // A reversed gesture hands the spring its actual downward velocity. The
    // navigation animation itself continues at the same physical speed instead
    // of running a second, out-of-sync spring for the page.
    final velocity = _releaseVelocity ?? controller!.velocity;
    _releaseVelocity = null;
    return _PlayerRouteSpring(
      from: _reduceMotion ? target : controller!.value,
      to: target,
      velocity: _reduceMotion ? 0 : velocity,
    );
  }

  /// Whether a finger owns the transition right now.
  ///
  /// The drag writes [controller] directly, and its release supplies the
  /// spring's initial velocity in the same visible coordinate.
  bool _dragging = false;

  @override
  bool get canStart =>
      isCurrent && !_dragging && (controller?.value ?? 0) > .001;

  @override
  void startPull() {
    _dragging = true;
    _initialOpen = controller!.value;
    _settled.value = false;
    controller?.stop();
  }

  @override
  void updatePull(double progress) {
    // Stay off the lower bound: popping, not dragging, finishes the dismissal.
    controller?.value = (_initialOpen - progress).clamp(
      .001,
      _initialOpen > 1 ? _initialOpen : 1.0,
    );
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
      _releaseVelocity =
          -velocity / MediaQuery.sizeOf(navigator!.context).height;
      navigator?.pop();
      return;
    }
    PlayerPageMotion.animate(
      controller!,
      1,
      compact: _compact,
      velocity: -velocity / MediaQuery.sizeOf(navigator!.context).height,
      releasedPull: true,
      reduceMotion: _reduceMotion,
    );
  }

  @override
  void cancelPull() {
    _dragging = false;
    PlayerPageMotion.animate(
      controller!,
      1,
      compact: _compact,
      velocity: 0,
      releasedPull: true,
      reduceMotion: _reduceMotion,
    );
  }

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => PlayerPageMotion.spring.duration;

  @override
  Duration get reverseTransitionDuration => transitionDuration;

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
    final physical = controller!.view;
    return AnimatedBuilder(
      animation: physical,
      child: MotionSnapshot(animation: physical, child: child),
      builder: (BuildContext context, Widget? child) {
        final double travelled = physical.value;
        // The page is still mounted for the reverse transition. Pause its
        // ambient and lyric tickers so the compositor can move one stable
        // layer offscreen without also repainting the full player each frame.
        final bool tickersEnabled =
            !_dragging && physical.status == AnimationStatus.completed;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (travelled > 1) const ColoredBox(color: Colors.black),
            FractionalTranslation(
              translation: Offset(0, 1 - travelled),
              child: TickerMode(enabled: tickersEnabled, child: child!),
            ),
          ],
        );
      },
    );
  }
}

/// Follows the player's physical spring while keeping the Navigator's own
/// progress exactly synchronized with the handoff velocity at every frame.
class _PlayerRouteSpring extends Simulation {
  _PlayerRouteSpring({
    required this.from,
    required this.to,
    required this.velocity,
  }) : progress = PlayerPageMotion.simulation(
         from: from,
         to: to,
         compact: true,
         velocity: velocity,
       );

  final double from, to, velocity;
  final Simulation progress;

  @override
  double x(double time) => progress.x(time);

  @override
  double dx(double time) => progress.dx(time);

  @override
  bool isDone(double time) => progress.isDone(time);
}

class _ClampedPlayerProgress extends Animatable<double> {
  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}
