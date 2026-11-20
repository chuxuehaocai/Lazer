import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import 'wallpaper_tint.dart';

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
/// using a veil; content opacity remains independent.
///
/// [opacity] is the veil, in the same direction as every other background
/// mode: 1 covers the material completely with the theme surface, 0 hands the
/// window over to the material alone.
///
/// DWM paints Mica from the desktop wallpaper's tint, and a desktop it never
/// sampled — an animated wallpaper, or a picture the shell was never told
/// about — leaves it a flat neutral sheet in dark mode. So the veil carries
/// the wallpaper's own average colour, which is the tint DWM would have used
/// had it read the same image, and it stops short of covering the material:
/// either end alone reads as a flat rectangle.
class MicaSurface extends StatelessWidget {
  const MicaSurface({super.key, this.opacity = 1});

  /// How much of the wallpaper average may enter the veil. Enough to carry the
  /// wallpaper's hue through a dark theme, little enough that a bright wallpaper
  /// does not wash the window out.
  static const double wallpaperWeight = .35;

  /// Where a veil may sit in a material mode. The material is composited
  /// beneath it, so neither end may take the whole window: a full veil hides
  /// the material, and none leaves the flat sheet DWM paints without a tint.
  static const double minMaterialVeil = kMaterialVeilMin;
  static const double maxMaterialVeil = kMaterialVeilMax;

  final double opacity;

  /// The wallpaper tinted over the theme surface by [wallpaperWeight].
  static Color veilFor(Color surface, Color? wallpaper) => wallpaper == null
      ? surface
      : Color.lerp(surface, wallpaper, wallpaperWeight) ?? surface;

  @override
  Widget build(BuildContext context) {
    final Color surface = Theme.of(context).colorScheme.surface;
    final bool active = WindowsBackdropScope.activeOf(context);
    return _WallpaperTintedVeil(
      surface: surface,
      opacity: active ? opacity.clamp(minMaterialVeil, maxMaterialVeil) : 1,
    );
  }
}

/// Reads the wallpaper once, then repaints the veil when it arrives. The window
/// opens on the theme surface and warms into the wallpaper tint a frame later,
/// which is invisible next to the entrance animation and keeps start-up free of
/// file IO.
class _WallpaperTintedVeil extends StatefulWidget {
  const _WallpaperTintedVeil({required this.surface, required this.opacity});
  final Color surface;
  final double opacity;

  @override
  State<_WallpaperTintedVeil> createState() => _WallpaperTintedVeilState();
}

class _WallpaperTintedVeilState extends State<_WallpaperTintedVeil> {
  Color? _wallpaper;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final Color? color = await desktopWallpaperTint();
    if (!mounted) return;
    setState(() {
      _wallpaper = color;
      _resolved = true;
    });
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: MicaSurface.veilFor(
      widget.surface,
      _resolved ? _wallpaper : null,
    ).withValues(alpha: widget.opacity),
  );
}
