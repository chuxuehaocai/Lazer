import '../state/build_safe_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

import '../navigation/pull_down_to_close.dart';
import '../navigation/system_back_gesture.dart';
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
  final ValueNotifier<bool> _settled = BuildSafeValueNotifier(false);
  NavigatorState? _systemGestureNavigator;
  AnimationStatusListener? _systemGestureRelease;
  bool _systemGestureSettling = false;
  bool _leaving = false;
  bool _disposed = false;

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
    _disposed = true;
    _dragging = false;
    _clearSystemGestureRelease();
    final nav = _systemGestureNavigator;
    if (nav != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _releaseSystemGesture(nav),
      );
    }
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
        layoutStyle: state.layoutStyle,
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
      !_disposed &&
      !_leaving &&
      !_dragging &&
      isCurrent &&
      isActive &&
      !isFirst &&
      !willHandlePopInternally &&
      popDisposition == RoutePopDisposition.pop &&
      !(navigator?.userGestureInProgress ?? true) &&
      (controller?.value ?? 0) > .001;

  @override
  void startPull() {
    if (!canStart) return;
    _dragging = true;
    _initialOpen = controller!.value;
    _settled.value = false;
    controller?.stop();
  }

  @override
  void updatePull(double progress) {
    if (!_dragging || _disposed || _leaving || !progress.isFinite) return;
    if (!isCurrent) {
      cancelPull();
      return;
    }
    // Stay off the lower bound: popping, not dragging, finishes the dismissal.
    controller?.value = (_initialOpen - progress).clamp(
      .001,
      _initialOpen > 1 ? _initialOpen : 1.0,
    );
  }

  @override
  void endPull(double velocity) {
    if (!_dragging || _disposed || _leaving) return;
    _dragging = false;
    if (!isActive) return;
    if (!velocity.isFinite) velocity = 0;
    final double open = controller?.value ?? 1;
    final double pulled = 1 - open;
    final bool dismiss = velocity < -900
        ? false
        : (velocity > 900 && pulled > .02) || pulled >= .22;
    if (dismiss &&
        isCurrent &&
        !willHandlePopInternally &&
        popDisposition == RoutePopDisposition.pop) {
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
    if (!_dragging || _disposed || _leaving) return;
    _dragging = false;
    if (!isActive) return;
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
  bool didPop(void result) {
    final popped = super.didPop(result);
    if (popped) {
      // A close button or system back can win while a finger is still down.
      // Its later update/cancel must not stop or reverse the exit animation.
      _leaving = true;
      _dragging = false;
    }
    return popped;
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute != null) cancelPull();
  }

  @override
  bool get popGestureEnabled =>
      !_disposed && !_leaving && !_dragging && super.popGestureEnabled;

  @override
  void handleStartBackGesture({double progress = 0}) {
    if (_disposed ||
        _leaving ||
        !isCurrent ||
        _systemGestureNavigator != null) {
      return;
    }
    cancelPull();
    _systemGestureNavigator = navigator;
    _systemGestureSettling = false;
    super.handleStartBackGesture(progress: progress);
  }

  @override
  void handleCommitBackGesture() {
    final nav = _systemGestureNavigator;
    if (_disposed || nav == null || _systemGestureSettling) return;
    _systemGestureSettling = true;
    if (isCurrent) {
      nav.pop();
    }
    if (!_leaving && isActive) {
      controller!.animateWith(createSimulation(forward: true));
    }
    // TransitionRoute's default commit restarts at upperBound. This player's
    // physical spring is unbounded, so its upperBound is infinity. Continue
    // from the finite finger position instead.
    _releaseSystemGestureWhenSettled(nav);
  }

  @override
  void handleUpdateBackGestureProgress({required double progress}) {
    if (_disposed ||
        _leaving ||
        _systemGestureNavigator == null ||
        _systemGestureSettling ||
        !progress.isFinite) {
      return;
    }
    super.handleUpdateBackGestureProgress(progress: progress.clamp(0.0, 1.0));
  }

  @override
  void handleCancelBackGesture() {
    final nav = _systemGestureNavigator;
    if (_disposed || nav == null || _systemGestureSettling) return;
    _systemGestureSettling = true;
    if (!_leaving && isActive) {
      controller!.animateWith(createSimulation(forward: true));
    }
    _releaseSystemGestureWhenSettled(nav);
  }

  void _releaseSystemGestureWhenSettled(NavigatorState nav) {
    _clearSystemGestureRelease();
    if (controller!.isAnimating) {
      _systemGestureRelease = (status) {
        if (status != AnimationStatus.completed &&
            status != AnimationStatus.dismissed) {
          return;
        }
        _clearSystemGestureRelease();
        _releaseSystemGesture(nav);
      };
      controller!.addStatusListener(_systemGestureRelease!);
    } else {
      _releaseSystemGesture(nav);
    }
  }

  void _clearSystemGestureRelease() {
    final release = _systemGestureRelease;
    if (release == null) return;
    controller?.removeStatusListener(release);
    _systemGestureRelease = null;
  }

  void _releaseSystemGesture(NavigatorState nav) {
    if (_systemGestureNavigator != nav) return;
    _systemGestureNavigator = null;
    _systemGestureSettling = false;
    if (nav.mounted && nav.userGestureInProgress) nav.didStopUserGesture();
  }

  @override
  // The player moves off the screen during the system back gesture. Keeping
  // the route opaque makes Navigator stop painting the page underneath, so
  // the exposed area falls through to a black window instead of the browse
  // page's configured background.
  bool get opaque => false;

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
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    if (MediaQuery.disableAnimationsOf(context)) {
      return ReducedMotionBackGesture(route: this, child: child);
    }
    // Timed motion curves the controller itself. A drag and its released
    // continuation consequently share the exact same visible coordinate.
    final physical = controller!.view;
    return AnimatedBuilder(
      animation: Listenable.merge([
        physical,
        navigator!.userGestureInProgressNotifier,
      ]),
      child: MotionSnapshot(
        animation: physical,
        snapshotForward: false,
        child: child,
      ),
      builder: (BuildContext context, Widget? child) {
        final systemBack = mobile && popGestureInProgress && !_dragging;
        final double travelled = systemBack ? 1 : physical.value;
        // The page is still mounted for the reverse transition. Pause its
        // ambient and lyric tickers so the compositor can move one stable
        // layer offscreen without also repainting the full player each frame.
        // The entrance must stay live: freezing it made a slow spring slide a
        // still image up and only start the player once the motion ended.
        final bool tickersEnabled =
            !_dragging && physical.status != AnimationStatus.reverse;
        final page = Stack(
          fit: StackFit.expand,
          children: [
            FractionalTranslation(
              translation: Offset(
                0,
                MediaQuery.disableAnimationsOf(context) ? 0 : 1 - travelled,
              ),
              child: TickerMode(enabled: tickersEnabled, child: child!),
            ),
          ],
        );
        if (platform == TargetPlatform.android) {
          return const PredictiveBackFullscreenPageTransitionsBuilder()
              .buildTransitions(
                this,
                context,
                systemBack ? animation : kAlwaysCompleteAnimation,
                secondaryAnimation,
                page,
              );
        }
        if (platform == TargetPlatform.iOS) {
          return const CupertinoPageTransitionsBuilder().buildTransitions(
            this,
            context,
            systemBack ? animation : kAlwaysCompleteAnimation,
            secondaryAnimation,
            page,
          );
        }
        return page;
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
