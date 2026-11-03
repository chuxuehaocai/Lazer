import 'package:flutter/material.dart';

import '../navigation/pull_down_to_close.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import 'now_playing_page.dart';
import 'player_page_motion.dart';
import '../animation/motion_snapshot.dart';
import '../animation/apple_spring.dart';

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
    final releasedPull = _releaseVelocity != null;
    final velocity = _releaseVelocity ?? controller!.velocity;
    _releaseVelocity = null;
    return PlayerPageMotion.simulation(
      from: _reduceMotion ? target : controller!.value,
      to: target,
      compact: _compact,
      releasedPull: releasedPull,
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
    controller?.value = (_initialOpen - progress).clamp(.001, 1);
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
    controller?.springTo(
      1,
      velocity: -velocity / MediaQuery.sizeOf(navigator!.context).height,
      reduceMotion: _reduceMotion,
    );
  }

  @override
  void cancelPull() {
    _dragging = false;
    controller?.springTo(1, velocity: 0, reduceMotion: _reduceMotion);
  }

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => _compact
      ? const Duration(milliseconds: 300)
      : PlayerPageMotion.desktopDuration;

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
