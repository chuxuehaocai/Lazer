import 'dart:async';
import 'dart:ui' as ui;

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

/// The system material, plus the wallpaper it was supposed to be made of.
///
/// [opacity] is the veil, in the same direction as every other background
/// mode: 1 covers the material completely with the theme surface, 0 hands the
/// window over to the material alone.
///
/// DWM composites the material, but it can only build it from a wallpaper the
/// shell owns. On a desktop painted by a third-party animated wallpaper the
/// material degrades to one flat neutral colour, which is what "Mica looks
/// broken" was. So the same wallpaper is drawn here, heavily blurred and
/// drained of colour, *under* the material and *above* it via the veil: the
/// surface then carries the wallpaper's soft light and shade instead of a flat
/// film of its average colour.
class MicaSurface extends StatelessWidget {
  const MicaSurface({super.key, this.opacity = 1});

  /// Where a veil may sit in a material mode. The material is composited
  /// beneath it, so neither end may take the whole window: a full veil hides
  /// the material, and none leaves the flat sheet DWM paints without a tint.
  static const double minMaterialVeil = kMaterialVeilMin;
  static const double maxMaterialVeil = kMaterialVeilMax;

  final double opacity;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool active = WindowsBackdropScope.activeOf(context);
    return _MaterialField(
      surface: theme.colorScheme.surface,
      dark: theme.brightness == Brightness.dark,
      opacity: active ? opacity.clamp(minMaterialVeil, maxMaterialVeil) : 1,
    );
  }
}

/// Draws the wallpaper, then the theme surface over it.
///
/// The wallpaper arrives a frame after start-up, which is invisible beside the
/// window's own entrance and keeps the first frame free of file IO.
class _MaterialField extends StatefulWidget {
  const _MaterialField({
    required this.surface,
    required this.dark,
    required this.opacity,
  });

  final Color surface;
  final bool dark;
  final double opacity;

  @override
  State<_MaterialField> createState() => _MaterialFieldState();
}

class _MaterialFieldState extends State<_MaterialField> {
  /// How much of the wallpaper field sits over the system material. It stays
  /// short of opaque on purpose: where DWM does have a wallpaper to sample,
  /// its material is the better half and must keep showing through. Where it
  /// does not, this field is what gives the window any light and shade at all.
  static const double _fieldAlpha = .62;

  ImageProvider? _wallpaper;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final ui.Image? image = await desktopWallpaperImage();
    if (!mounted || image == null) return;
    setState(() => _wallpaper = _WallpaperImage(image));
  }

  @override
  Widget build(BuildContext context) {
    final Widget veil = ColoredBox(
      color: widget.surface.withValues(alpha: widget.opacity),
    );
    if (_wallpaper == null) return veil;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Blur comes for free: the source is a 96 px strip scaled up to the
        // window, which is exactly the soft field a system material shows.
        Opacity(
          opacity: _fieldAlpha,
          child: ColorFiltered(
            colorFilter: materialWallpaperFilter(dark: widget.dark),
            child: Image(
              image: _wallpaper!,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
          ),
        ),
        veil,
      ],
    );
  }
}

/// Hands a decoded [ui.Image] to the widget layer without re-decoding it.
class _WallpaperImage extends ImageProvider<_WallpaperImage> {
  const _WallpaperImage(this.image);
  final ui.Image image;

  @override
  Future<_WallpaperImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_WallpaperImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _WallpaperImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())),
  );

  @override
  bool operator ==(Object other) =>
      other is _WallpaperImage && other.image == image;

  @override
  int get hashCode => image.hashCode;
}
