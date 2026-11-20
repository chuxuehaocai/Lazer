import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';
import '../state/ui_preferences.dart';

bool get supportsWindowsMica =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Native state is shared by all routes: DWM paints the HWND, not a Flutter
/// widget. Serialize updates so a late player-open response cannot override
/// the backdrop selected after closing the player.
class WindowsBackdrop extends StatefulWidget {
  const WindowsBackdrop({super.key, required this.state, required this.child});
  final AppState state;
  final Widget child;

  @override
  State<WindowsBackdrop> createState() => _WindowsBackdropState();
}

class _WindowsBackdropState extends State<WindowsBackdrop>
    with WindowListener, WidgetsBindingObserver {
  static const _channel = MethodChannel('dev.naominet.lazer/window_backdrop');
  (bool, bool)? _requested;
  Future<void> _pending = Future.value();
  bool _active = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_sync);
    widget.state.playerPresented.addListener(_sync);
    if (supportsWindowsMica) {
      windowManager.addListener(this);
      WidgetsBinding.instance.addObserver(this);
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'refresh') _refreshFrame();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(WindowsBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_sync);
      oldWidget.state.playerPresented.removeListener(_sync);
      widget.state.addListener(_sync);
      widget.state.playerPresented.addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    if (!supportsWindowsMica || !mounted) return;
    final state = widget.state;
    final mode = state.playerPresented.value
        ? state.playerBackground
        : state.backgroundMode;
    final options = (
      mode == AppBackgroundMode.windowsMica,
      state.playerPresented.value ||
          Theme.of(context).brightness == Brightness.dark,
    );
    if (options == _requested) return;
    _requested = options;
    _pending = _pending.then((_) async {
      if (!mounted || _requested != options) return;
      bool active = false;
      try {
        // DWM owns the native background. window_manager.setBackgroundColor
        // installs a legacy accent gradient that hides the Mica material.
        // The native runner extends the frame; MicaSurface exposes transparent
        // Flutter pixels only after that complete operation succeeds.
        active =
            await _channel.invokeMethod<bool>('setMica', {
              'enabled': options.$1,
              'dark': options.$2,
            }) ??
            false;
      } on MissingPluginException {
        // Web, old runner or tests: retain a readable opaque theme surface.
      } on PlatformException {
        // Composition can be unavailable in remote sessions or older Windows.
      }
      if (mounted && _requested == options && active != _active) {
        setState(() => _active = active);
      }
    });
    unawaited(_pending);
  }

  void _refreshFrame() {
    final state = widget.state;
    final mode = state.playerPresented.value
        ? state.playerBackground
        : state.backgroundMode;
    final dark =
        state.playerPresented.value ||
        Theme.of(context).brightness == Brightness.dark;
    _requested = null;
    _sync();
    // DWM samples the wallpaper when it installs the material and keeps that
    // sample, so a window that was already open never notices a new picture.
    // Rebuild the material whenever the window comes back to the foreground:
    // that is exactly when somebody returns from 个性化 after picking one.
    if (_active && mode == AppBackgroundMode.windowsMica) {
      unawaited(_refreshMaterial(dark));
    }
  }

  /// Asks the runner to drop and reinstall the material, which makes DWM take a
  /// fresh wallpaper sample. Silent on failures: an unusable sample is a
  /// cosmetic problem, not a reason to disturb the route.
  Future<void> _refreshMaterial(bool dark) async {
    try {
      await _channel.invokeMethod<bool>('refreshMaterial', {'dark': dark});
    } on MissingPluginException {
      // Older runner, or a platform without the channel.
    } on PlatformException {
      // Composition unavailable; the material is already gone.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshFrame();
  }

  @override
  void onWindowFocus() => _refreshFrame();

  @override
  void onWindowEnterFullScreen() => _refreshFrame();
  @override
  void onWindowLeaveFullScreen() => _refreshFrame();

  @override
  void dispose() {
    widget.state.removeListener(_sync);
    widget.state.playerPresented.removeListener(_sync);
    if (supportsWindowsMica) {
      windowManager.removeListener(this);
      WidgetsBinding.instance.removeObserver(this);
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      WindowsBackdropScope(active: _active, child: widget.child);
}

class WindowsBackdropScope extends InheritedWidget {
  const WindowsBackdropScope({
    super.key,
    required this.active,
    required super.child,
  });
  final bool active;
  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WindowsBackdropScope>()
          ?.active ??
      false;
  @override
  bool updateShouldNotify(WindowsBackdropScope oldWidget) =>
      oldWidget.active != active;
}

/// Mica itself is system controlled. DWM composites it into the window, and the
/// only thing this surface may do is get out of the way.
///
/// [opacity] is an optional theme veil over the material. It defaults to fully
/// transparent: painting anything opaque here replaces the material with a flat
/// colour, which is exactly what made Mica look like a grey sheet instead of a
/// material. The veil exists only for listeners who want the window tinted
/// towards the theme, and for the fallback below.
///
/// When the native material is not active — another platform, an older Windows,
/// a remote session whose composition is unavailable — nothing composites
/// underneath, so the surface has to be opaque or the window would show holes.
class MicaSurface extends StatelessWidget {
  const MicaSurface({super.key, this.opacity = 0});
  final double opacity;
  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return ColoredBox(
      color: surface.withValues(
        alpha: WindowsBackdropScope.activeOf(context) ? opacity.clamp(0, 1) : 1,
      ),
    );
  }
}
