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

class _WindowsBackdropState extends State<WindowsBackdrop> with WindowListener {
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
    _requested = null;
    _sync();
  }

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

/// Mica itself is system controlled. This slider changes its visible amount
/// using a theme-colored veil; content opacity remains independent.
///
/// [opacity] is the veil, in the same direction as every other background
/// mode: 1 covers the material completely with the theme surface, 0 hands the
/// window over to the material alone. Mica on a desktop whose wallpaper the
/// shell has no tint for renders a flat neutral sheet, so a veil is what keeps
/// the window readable as this app instead of a grey rectangle.
class MicaSurface extends StatelessWidget {
  const MicaSurface({super.key, this.opacity = 1});
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
