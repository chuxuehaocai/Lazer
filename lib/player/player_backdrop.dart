import '../widgets/build_safe_state.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../animation/motion_snapshot.dart';
import '../data/models.dart';
import '../ui/background.dart';
import '../state/ui_preferences.dart';
import '../theme/adaptive_contrast.dart';

/// The immersive player canvas: album-colour flow + a real, heavily blurred
/// cover bloom + Apple Music's dark vignette.
class AlbumBlurFlowCanvas extends StatefulWidget {
  const AlbumBlurFlowCanvas({
    super.key,
    required this.track,
    required this.mode,
    this.pageColor = Colors.transparent,
    this.animationsEnabled = true,
    this.quality = kDynamicBackgroundQualityDefault,
    this.preview = false,
    this.boundaryKey,
    this.onSeed,
    this.frameRate,
    this.solidColor,
    this.imagePath,
    this.uiAlpha = 0.7,
    this.imageAlignmentX = 0,
    this.imageAlignmentY = 0,
    this.imageScale = 1,
    this.blurSigma = 0,
    this.paletteLoader = albumPaletteForCover,
  });

  final Track? track;
  final ValueChanged<Color>? onSeed;
  final double? frameRate;
  final Color? solidColor;
  final String? imagePath;
  final double uiAlpha;
  final double imageAlignmentX;
  final double imageAlignmentY;
  final double imageScale;
  final double blurSigma;
  final AppBackgroundMode mode;
  final Color pageColor;
  final bool animationsEnabled;

  /// `动态背景渲染精度` from Settings, 0.1 … 1.0.
  final double quality;

  /// Paints the cheap stand-in canvas instead of the warped mesh. The player
  /// sets it while its entrance or exit slide is running.
  final bool preview;

  /// Lets the player capture the currently painted backdrop frame, e.g. for
  /// the exported lyric image.
  final Key? boundaryKey;

  /// Where this canvas reads the cover's colours from; tests hand in their own.
  final AlbumPaletteLoader paletteLoader;

  @override
  State<AlbumBlurFlowCanvas> createState() => _AlbumBlurFlowCanvasState();
}


/// Public player background surface. Browse uses [AlbumBlurFlowCanvas] directly
/// so a shell can keep one player surface and one browse surface without
/// confusing widget identity or palette lifetimes.
class AlbumBlurFlow extends StatelessWidget {
  const AlbumBlurFlow({
    super.key,
    required this.track,
    required this.mode,
    required this.pageColor,
    this.animationsEnabled = true,
    this.quality = kDynamicBackgroundQualityDefault,
    this.preview = false,
    this.boundaryKey,
    this.onSeed,
    this.frameRate,
    this.solidColor,
    this.imagePath,
    this.uiAlpha = .7,
    this.imageAlignmentX = 0,
    this.imageAlignmentY = 0,
    this.imageScale = 1,
    this.blurSigma = 0,
    this.paletteLoader = albumPaletteForCover,
  });

  final Track? track;
  final AppBackgroundMode mode;
  final Color pageColor;
  final bool animationsEnabled;
  final double quality;
  final bool preview;
  final Key? boundaryKey;
  final ValueChanged<Color?>? onSeed;
  final double? frameRate;
  final Color? solidColor;
  final String? imagePath;
  final double uiAlpha;
  final double imageAlignmentX;
  final double imageAlignmentY;
  final double imageScale;
  final double blurSigma;
  final AlbumPaletteLoader paletteLoader;

  @override
  Widget build(BuildContext context) => AlbumBlurFlowCanvas(
    track: track,
    mode: mode,
    pageColor: pageColor,
    animationsEnabled: animationsEnabled,
    quality: quality,
    preview: preview,
    boundaryKey: boundaryKey,
    onSeed: onSeed == null
        ? null
        : (Color color) => onSeed!(color),
    frameRate: frameRate,
    solidColor: solidColor,
    imagePath: imagePath,
    uiAlpha: uiAlpha,
    imageAlignmentX: imageAlignmentX,
    imageAlignmentY: imageAlignmentY,
    imageScale: imageScale,
    blurSigma: blurSigma,
    paletteLoader: paletteLoader,
  );
}

class _AlbumBlurFlowCanvasState extends State<AlbumBlurFlowCanvas>
    with BuildSafeState<AlbumBlurFlowCanvas> {
  List<Color> _colors = albumFlowColors(kAlbumDefaultSeed);
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_updatePalette());
  }

  @override
  void didUpdateWidget(covariant AlbumBlurFlowCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.id != widget.track?.id ||
        oldWidget.track?.coverUrl != widget.track?.coverUrl) {
      unawaited(_updatePalette());
    }
  }

  Future<void> _updatePalette() async {
    final int generation = ++_generation;
    final String? coverUrl = widget.track?.coverUrl;
    // Switch the canvas in this build. Waiting for the artwork must not leave
    // the previous track's palette visible throughout the retry window.
    final cached = widget.paletteLoader == albumPaletteForCover
        ? cachedAlbumPaletteForCover(coverUrl)
        : null;
    final List<Color> fallback =
        cached?.mesh ?? albumFlowColors(albumFallbackSeedForTrack(widget.track));
    if (mounted) {
      setState(() => _colors = fallback);
    } else {
      _colors = fallback;
    }
    final AlbumCoverPalette? palette = await albumPaletteForCoverWhenReady(
      widget.paletteLoader,
      coverUrl,
    );
    if (!mounted || generation != _generation) return;
    widget.onSeed?.call(palette?.seed ?? kAlbumDefaultSeed);
    if (palette != null && !identical(_colors, palette.mesh)) {
      setState(() => _colors = palette.mesh);
      MotionSnapshot.invalidate(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        key: widget.boundaryKey,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: widget.pageColor),
            if (widget.mode == AppBackgroundMode.solidColor)
              ColoredBox(
                color:
                    widget.solidColor ??
                    backgroundFromTheme(
                      Theme.of(context).colorScheme.primary,
                      Brightness.dark,
                    ),
              )
            else if (widget.mode == AppBackgroundMode.customImage)
              CustomImageBackdrop(
                path: widget.imagePath,
                pageColor: widget.pageColor,
                alignmentX: widget.imageAlignmentX,
                alignmentY: widget.imageAlignmentY,
                scale: widget.imageScale,
                blurSigma: widget.blurSigma,
              )
            else if (widget.mode != AppBackgroundMode.off)
              AlbumFlowBackground(
                key: ValueKey<String?>(widget.track?.id),
                colors: _colors,
                animated:
                    widget.animationsEnabled &&
                    widget.mode == AppBackgroundMode.nowPlayingDynamic,
                solid: false,
                frameRate: widget.frameRate,
                quality: widget.quality,
                preview: widget.preview,
              ),
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x99000000),
                      Color(0x22000000),
                      Color(0x44000000),
                      Color(0xE0000000),
                    ],
                    stops: <double>[0, .28, .62, 1],
                  ),
                ),
              ),
            ),
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-.35, -.25),
                    radius: 1.08,
                    colors: <Color>[Color(0x00000000), Color(0x75000000)],
                    stops: <double>[.42, 1],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
