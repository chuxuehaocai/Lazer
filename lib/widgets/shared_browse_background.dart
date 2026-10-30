import 'package:flutter/material.dart';

import '../legacy/legacy_background.dart';
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
class SharedBrowseBackground extends StatelessWidget {
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
  Widget build(BuildContext context) => BrowseBackgroundScope(
    child: AnimatedBuilder(
      animation: Listenable.merge([
        state,
        state.playerPresented,
        state.browseTransitionActive,
        navigation.moving,
        navigation.rootVisible,
      ]),
      child: child,
      builder: (context, child) {
        final apple = AppleSemanticColors.of(context);
        final painted = state.legacyBackground != LegacyBackgroundMode.off;
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
                        navigation.rootVisible.value) &&
                    !navigation.moving.value,
                child: LegacyAlbumBackdrop(
                  track: state.current,
                  mode: state.legacyBackground,
                  imagePath: state.legacyBackgroundImagePath,
                  uiAlpha: state.legacyUiAlpha,
                  quality: state.dynamicBackgroundQuality,
                  frameRate: state.browseBackgroundFps,
                  solidColor: state.browseBackgroundColor,
                ),
              ),
            if (painted)
              IgnorePointer(
                child: ColoredBox(
                  color: apple.background.withValues(
                    alpha: (state.legacyUiAlpha * .9).clamp(.56, .92),
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
  final ValueNotifier<bool> moving = ValueNotifier(false);
  final ValueNotifier<bool> rootVisible = ValueNotifier(true);
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
            final listener = _listeners.remove(animation);
            if (listener != null) animation.removeStatusListener(listener);
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
    if (animation == null || _listeners.containsKey(animation)) return;
    _active.add(animation);
    late AnimationStatusListener listener;
    listener = (status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        _active.remove(animation);
        animation.removeStatusListener(listener);
        _listeners.remove(animation);
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
