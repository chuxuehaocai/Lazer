import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../animation/apple_spring.dart';
import '../state/build_safe_notifier.dart';
import '../theme/app_palette.dart';
import '../tv/tv_mode.dart';
import 'window_chrome_surface.dart';

export 'window_chrome_surface.dart';

/// Connects the active player's controls to the window chrome outside its
/// navigator. The most recently attached presentation owns the chrome.
class WindowChromeController extends ValueNotifier<bool>
    with BuildSafeNotifier {
  WindowChromeController() : super(true);

  final List<_WindowChromeSource> _sources = [];
  final List<({Object owner, double width, bool active})> _actions = [];
  bool _disposed = false;

  bool get playerPresented => _sources.isNotEmpty;
  double get actionsWidth => _actions.lastOrNull?.width ?? 0;
  bool get actionsActive => _actions.lastOrNull?.active ?? false;

  /// Registers only geometry, keeping the actual buttons in their page's
  /// overlay portal so they retain their theme, route and action context.
  void updateActions(
    Object owner, {
    required double width,
    required bool active,
  }) {
    if (_disposed) return;
    final double oldWidth = actionsWidth;
    final bool oldActive = actionsActive;
    final index = _actions.indexWhere((entry) => identical(entry.owner, owner));
    final entry = (owner: owner, width: width, active: active);
    if (index < 0) {
      _actions.add(entry);
    } else {
      _actions[index] = entry;
    }
    if (oldWidth != actionsWidth || oldActive != actionsActive) {
      notifyListeners();
    }
  }

  void removeActions(Object owner) {
    if (_disposed) return;
    final double oldWidth = actionsWidth;
    final bool oldActive = actionsActive;
    _actions.removeWhere((entry) => identical(entry.owner, owner));
    if (oldWidth != actionsWidth || oldActive != actionsActive) {
      notifyListeners();
    }
  }

  void attach(
    ValueListenable<bool> source, {
    VoidCallback? onActivity,
    ValueChanged<int>? onPointerStart,
    ValueChanged<int>? onPointerEnd,
  }) {
    if (_disposed) return;
    final bool wasPresented = playerPresented;
    _removeSource(source);
    final binding = _WindowChromeSource(
      source: source,
      onActivity: onActivity,
      onPointerStart: onPointerStart,
      onPointerEnd: onPointerEnd,
      onChanged: _sync,
    );
    _sources.add(binding);
    source.addListener(binding.onChanged);
    _sync(presentationChanged: wasPresented != playerPresented);
  }

  void detach(ValueListenable<bool> source) {
    if (_disposed) return;
    final bool wasPresented = playerPresented;
    _removeSource(source);
    _sync(presentationChanged: wasPresented != playerPresented);
  }

  void _removeSource(ValueListenable<bool> source) {
    final index = _sources.indexWhere(
      (binding) => identical(binding.source, source),
    );
    if (index < 0) return;
    final binding = _sources.removeAt(index);
    binding.source.removeListener(binding.onChanged);
  }

  void _sync({bool presentationChanged = false}) {
    if (_disposed) return;
    final bool next = _sources.isEmpty ? true : _sources.last.source.value;
    if (value != next) {
      value = next;
    } else if (presentationChanged) {
      notifyListeners();
    }
  }

  void pointerDown(int pointer) {
    if (_disposed || _sources.isEmpty) return;
    final active = _sources.last;
    active.onPointerStart?.call(pointer);
    active.onActivity?.call();
  }

  void pointerUp(int pointer) {
    if (_disposed || _sources.isEmpty) return;
    _sources.last.onPointerEnd?.call(pointer);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final binding in _sources) {
      binding.source.removeListener(binding.onChanged);
    }
    _sources.clear();
    _actions.clear();
    super.dispose();
  }
}

class _WindowChromeSource {
  const _WindowChromeSource({
    required this.source,
    required this.onActivity,
    required this.onPointerStart,
    required this.onPointerEnd,
    required this.onChanged,
  });

  final ValueListenable<bool> source;
  final VoidCallback? onActivity;
  final ValueChanged<int>? onPointerStart, onPointerEnd;
  final VoidCallback onChanged;
}

class WindowChromeScope extends InheritedWidget {
  const WindowChromeScope({
    super.key,
    required this.controller,
    this.inline = false,
    this.reveal,
    this.chromeTheme,
    required super.child,
  });

  final WindowChromeController controller;
  final bool inline;
  final Animation<double>? reveal;
  final ThemeData? chromeTheme;

  static WindowChromeScope? maybeLayoutOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowChromeScope>();

  static WindowChromeController? maybeOf(BuildContext context) =>
      maybeLayoutOf(context)?.controller;

  @override
  bool updateShouldNotify(WindowChromeScope oldWidget) =>
      controller != oldWidget.controller ||
      inline != oldWidget.inline ||
      reveal != oldWidget.reveal ||
      chromeTheme != oldWidget.chromeTheme;
}

/// Reserves the existing header height while its actions use the root overlay.
class WindowChromeHeader extends StatelessWidget {
  const WindowChromeHeader({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final layout = WindowChromeScope.maybeLayoutOf(context);
    if (layout?.inline != true) return child;
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: child,
    );
  }
}

/// Song actions occupy the extending left half of the window capsule. The
/// surface is painted once by WindowTitleArea; this portal paints only buttons.
class WindowChromeActions extends StatefulWidget {
  const WindowChromeActions({super.key, required this.children});

  final List<Widget> children;

  @override
  State<WindowChromeActions> createState() => _WindowChromeActionsState();
}

class _WindowChromeActionsState extends State<WindowChromeActions> {
  late final _portal = OverlayPortalController()..show();
  WindowChromeController? _chrome;

  void _register(WindowChromeController? chrome, double width, bool active) {
    if (_chrome != chrome) {
      _chrome?.removeActions(this);
      _chrome = chrome;
    }
    _chrome?.updateActions(this, width: width, active: active);
  }

  @override
  void dispose() {
    _chrome?.removeActions(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = WindowChromeScope.maybeLayoutOf(context);
    final reveal = layout?.reveal;
    final double width = kWindowChromeButtonWidth * widget.children.length;
    if (layout?.inline != true || reveal == null || TvScope.isActive(context)) {
      _register(null, 0, false);
      return DecoratedBox(
        key: const ValueKey('desktop-player-actions'),
        decoration: BoxDecoration(
          color: context.colors.onPlayer.withValues(alpha: .045),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: context.colors.onPlayer.withValues(alpha: .18),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.children.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                widget.children[i],
              ],
            ],
          ),
        ),
      );
    }
    final bool routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _register(layout!.controller, width, routeCurrent);
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) => Positioned(
        top: 12,
        right: 20 + kWindowChromeButtonWidth * 3,
        child: Offstage(
          offstage: !routeCurrent,
          child: Theme(
            data: layout.chromeTheme ?? Theme.of(context),
            child: Listener(
              onPointerDown: (event) =>
                  layout.controller.pointerDown(event.pointer),
              onPointerUp: (event) =>
                  layout.controller.pointerUp(event.pointer),
              onPointerCancel: (event) =>
                  layout.controller.pointerUp(event.pointer),
              child: AnimatedBuilder(
                animation: reveal,
                builder: (context, _) {
                  final double progress = 1 - reveal.value;
                  final bool active =
                      layout.controller.playerPresented &&
                      progress >= .95 &&
                      routeCurrent;
                  return ExcludeFocus(
                    excluding: !active,
                    child: ExcludeSemantics(
                      excluding: !active,
                      child: IgnorePointer(
                        ignoring: !active,
                        child: SizedBox(
                          key: const ValueKey('desktop-player-actions'),
                          width: width * math.max(0, progress),
                          height: kWindowChromeHeight,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(kWindowChromeHeight / 2),
                            ),
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.centerRight,
                                minWidth: width,
                                maxWidth: width,
                                minHeight: kWindowChromeHeight,
                                maxHeight: kWindowChromeHeight,
                                child: Transform.translate(
                                  key: const ValueKey(
                                    'window-chrome-actions-slide',
                                  ),
                                  offset: Offset(width * (1 - progress), 0),
                                  child: Opacity(
                                    key: const ValueKey(
                                      'window-chrome-actions-fade',
                                    ),
                                    opacity: progress.clamp(0.0, 1.0),
                                    child: _WindowChromeButtonTheme(
                                      child: SizedBox(
                                        width: width,
                                        height: kWindowChromeHeight,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            for (final child in widget.children)
                                              SizedBox(
                                                width: kWindowChromeButtonWidth,
                                                height: kWindowChromeHeight,
                                                child: child,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      // Keep the artwork/lyrics canvas steady throughout the unfold.
      child: SizedBox(width: width, height: 52),
    );
  }
}

/// Keeps the collapse affordance level with the caption, independently of the
/// player's entrance transform. Other layouts retain their normal toolbar.
class WindowChromeCollapse extends StatefulWidget {
  const WindowChromeCollapse({super.key, required this.child});

  final Widget child;

  @override
  State<WindowChromeCollapse> createState() => _WindowChromeCollapseState();
}

class _WindowChromeCollapseState extends State<WindowChromeCollapse> {
  late final _portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) {
    final layout = WindowChromeScope.maybeLayoutOf(context);
    final reveal = layout?.reveal;
    if (layout == null ||
        !layout.inline ||
        reveal == null ||
        TvScope.isActive(context)) {
      return widget.child;
    }
    final bool routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) => Positioned(
        top: 12,
        left: 16,
        child: Offstage(
          offstage: !routeCurrent,
          child: Listener(
            onPointerDown: (event) =>
                layout.controller.pointerDown(event.pointer),
            onPointerUp: (event) => layout.controller.pointerUp(event.pointer),
            onPointerCancel: (event) =>
                layout.controller.pointerUp(event.pointer),
            child: AnimatedBuilder(
              animation: reveal,
              builder: (context, child) {
                final double progress = 1 - reveal.value;
                final bool active =
                    layout.controller.playerPresented &&
                    progress > 0 &&
                    routeCurrent;
                return ExcludeFocus(
                  excluding: !active,
                  child: ExcludeSemantics(
                    excluding: !active,
                    child: IgnorePointer(
                      ignoring: !active,
                      child: Opacity(
                        opacity: progress.clamp(0.0, 1.0),
                        child: child,
                      ),
                    ),
                  ),
                );
              },
              child: Theme(
                data: layout.chromeTheme ?? Theme.of(context),
                child: _WindowChromeButtonTheme(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      kWindowChromeHeight / 2,
                    ),
                    child: SizedBox(
                      width: kWindowChromeButtonWidth,
                      height: kWindowChromeHeight,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: const SizedBox(width: kWindowChromeButtonWidth, height: 52),
    );
  }
}

class _WindowChromeButtonTheme extends StatelessWidget {
  const _WindowChromeButtonTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(
            Size(kWindowChromeButtonWidth, kWindowChromeHeight),
          ),
          minimumSize: const WidgetStatePropertyAll(Size.zero),
          maximumSize: const WidgetStatePropertyAll(
            Size(kWindowChromeButtonWidth, kWindowChromeHeight),
          ),
          iconSize: const WidgetStatePropertyAll(18),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => scheme.onSurfaceVariant.withValues(
              alpha: states.contains(WidgetState.disabled) ? .4 : 1,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => scheme.onSurface.withValues(
              alpha: states.contains(WidgetState.pressed)
                  ? .13
                  : states.contains(WidgetState.hovered)
                  ? .07
                  : 0,
            ),
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      child: child,
    );
  }
}

/// Fades the title upwards while releasing its height to the page below.
/// A single spring keeps both movements together, including on interruption.
class WindowChromeTransition extends StatefulWidget {
  const WindowChromeTransition({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  State<WindowChromeTransition> createState() => _WindowChromeTransitionState();
}

class _WindowChromeTransitionState extends State<WindowChromeTransition>
    with SingleTickerProviderStateMixin {
  static const _spring = AppleSpring(
    duration: Duration(milliseconds: 500),
    bounce: .08,
  );

  late final _progress = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final _opacity = _progress.drive(const _ClampedOpacity());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = widget.visible ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant WindowChromeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    _progress.springTo(
      widget.visible ? 1 : 0,
      spring: _spring,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: !widget.visible,
    child: ExcludeSemantics(
      excluding: !widget.visible,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _progress,
            builder: (context, child) => Align(
              key: const ValueKey('window-chrome-size'),
              alignment: Alignment.topCenter,
              heightFactor: math.max(0, _progress.value),
              child: FractionalTranslation(
                key: const ValueKey('window-chrome-slide'),
                translation: Offset(0, _progress.value - 1),
                child: child,
              ),
            ),
            child: FadeTransition(
              key: const ValueKey('window-chrome-fade'),
              opacity: _opacity,
              child: widget.child,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ClampedOpacity extends Animatable<double> {
  const _ClampedOpacity();

  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}
