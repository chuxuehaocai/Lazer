import '../state/build_safe_notifier.dart';
import 'build_safe_state.dart';
import 'package:flutter/material.dart';

import '../ui/background.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';

class BrowseBackgroundScope extends InheritedWidget {
  const BrowseBackgroundScope({super.key, required super.child});
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BrowseBackgroundScope>() !=
      null;
  @override
  bool updateShouldNotify(BrowseBackgroundScope oldWidget) => false;
}

/// One persistent canvas below the navigator, shared by every browsing route.
class SharedBrowseBackground extends StatefulWidget {
  const SharedBrowseBackground({
    super.key,
    required this.state,
    required this.navigation,
    required this.child,
  });
  final AppState state;
  final BrowseNavigationObserver navigation;
  final Widget child;

  @override
  State<SharedBrowseBackground> createState() => _SharedBrowseBackgroundState();
}

class _SharedBrowseBackgroundState extends State<SharedBrowseBackground>
    with BuildSafeState<SharedBrowseBackground> {
  late Object _signature;
  late Listenable _motion;

  Object get _backgroundSignature {
    final state = widget.state;
    final track = state.current;
    return (
      (track?.id, track?.coverUrl, track?.coverSeed),
      state.backgroundMode,
      state.backgroundImagePath,
      state.backgroundImageAlignmentX,
      state.backgroundImageAlignmentY,
      state.backgroundImageScale,
      state.backgroundBlurEnabled ? state.backgroundBlur : 0,
      state.uiAlpha,
      state.dynamicBackgroundQuality,
      state.browseBackgroundFps,
      state.browseBackgroundColor,
    );
  }

  Listenable get _motionListenable => Listenable.merge([
    widget.state.playerPresented,
    widget.state.browseTransitionActive,
    widget.navigation.moving,
    widget.navigation.rootVisible,
  ]);

  @override
  void initState() {
    super.initState();
    _signature = _backgroundSignature;
    _motion = _motionListenable;
    widget.state.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    final next = _backgroundSignature;
    if (_signature == next) return;
    setState(() => _signature = next);
  }

  @override
  void didUpdateWidget(SharedBrowseBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onStateChanged);
      widget.state.addListener(_onStateChanged);
      _signature = _backgroundSignature;
    }
    if (oldWidget.state != widget.state ||
        oldWidget.navigation != widget.navigation) {
      _motion = _motionListenable;
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BrowseBackgroundScope(
    child: AnimatedBuilder(
      // Likes, downloads, volume and account updates do not change these
      // pixels. Only the background selection and route visibility do.
      animation: _motion,
      child: widget.child,
      builder: (context, child) {
        final state = widget.state;
        final navigation = widget.navigation;
        final apple = AppleSemanticColors.of(context);
        final painted = state.backgroundMode != AppBackgroundMode.off;
        final canvas =
            !painted && Theme.of(context).brightness == Brightness.dark
            ? AppleColors.darkCanvas
            : apple.background;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: canvas),
            if (painted)
              TickerMode(
                enabled:
                    !state.playerPresented.value &&
                    !(state.browseTransitionActive.value &&
                        navigation.rootVisible.value &&
                        !navigation.moving.value),
                child: AlbumBlurFlowCanvas(
                  track: state.current,
                  mode: state.backgroundMode,
                  pageColor: Colors.transparent,
                  animationsEnabled:
                      state.backgroundMode ==
                      AppBackgroundMode.nowPlayingDynamic,
                  imagePath: state.backgroundImagePath,
                  uiAlpha: state.uiAlpha,
                  imageAlignmentX: state.backgroundImageAlignmentX,
                  imageAlignmentY: state.backgroundImageAlignmentY,
                  imageScale: state.backgroundImageScale,
                  blurSigma: state.backgroundBlurEnabled
                      ? state.backgroundBlur
                      : 0,
                  quality: state.dynamicBackgroundQuality,
                  frameRate: state.browseBackgroundFps,
                  solidColor: state.browseBackgroundColor,
                ),
              ),
            if (painted)
              IgnorePointer(
                child: ColoredBox(
                  color: apple.background.withValues(
                    alpha: (state.uiAlpha * .9).clamp(.56, .92),
                  ),
                ),
              ),
            child!,
          ],
        );
      },
    ),
  );
}

class BrowseNavigationObserver extends NavigatorObserver {
  final ValueNotifier<bool> moving = BuildSafeValueNotifier(false);
  final ValueNotifier<bool> rootVisible = BuildSafeValueNotifier(true);
  final List<Route<dynamic>> _routes = [];
  final Map<Animation<double>, AnimationStatusListener> _listeners = {};
  final Set<Animation<double>> _active = {};
  bool _scheduled = false, _disposed = false;

  void _report() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) {
        rootVisible.value = _routes.length <= 1;
        for (final animation in _active.toList()) {
          if (animation.status == AnimationStatus.completed ||
              animation.status == AnimationStatus.dismissed) {
            _active.remove(animation);
          }
        }
        moving.value = _active.isNotEmpty;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _watch(Route<dynamic> route) {
    if (route is! TransitionRoute<dynamic>) return;
    final animation = route.animation;
    if (animation == null) return;
    _active.add(animation);
    if (_listeners.containsKey(animation)) {
      _report();
      return;
    }
    late AnimationStatusListener listener;
    listener = (status) {
      // A spring route can emit its initial dismissed status before its first
      // forward sample. Keep watching until the route is actually removed.
      if (status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        _active.add(animation);
      }
      _report();
    };
    _listeners[animation] = listener;
    animation.addStatusListener(listener);
    // ModalRoute may detach its proxy before forwarding the final dismissed
    // status. Route completion is authoritative even when that status is lost.
    route.completed.then((_) {
      if (_disposed) return;
      final attached = _listeners.remove(animation);
      if (attached != null) animation.removeStatusListener(attached);
      _active.remove(animation);
      _report();
    });
    _report();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _report();
    if (previousRoute != null) _watch(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _report();
    _watch(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    _report();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _report();
    if (route is TransitionRoute<dynamic> && route.animation != null) {
      final animation = route.animation!;
      final listener = _listeners.remove(animation);
      if (listener != null) animation.removeStatusListener(listener);
      _active.remove(animation);
      _report();
    }
  }

  void dispose() {
    _disposed = true;
    for (final entry in _listeners.entries) {
      entry.key.removeStatusListener(entry.value);
    }
    _listeners.clear();
    _active.clear();
    _routes.clear();
    moving.dispose();
    rootVisible.dispose();
  }
}
