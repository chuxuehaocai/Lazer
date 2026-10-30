import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../legacy/legacy_background.dart';
import '../state/ui_preferences.dart';
import '../theme/adaptive_contrast.dart';

/// The immersive player canvas: album-colour flow + a real, heavily blurred
/// cover bloom + Apple Music's dark vignette.
class AlbumBlurFlow extends StatefulWidget {
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
  });

  final Track? track;
  final ValueChanged<Color?>? onSeed;
  final double? frameRate;
  final Color? solidColor;
  final String? imagePath;
  final LegacyBackgroundMode mode;
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

  @override
  State<AlbumBlurFlow> createState() => _AlbumBlurFlowState();
}

class _AlbumBlurFlowState extends State<AlbumBlurFlow> {
  List<Color> _colors = albumFlowColors(kAlbumDefaultSeed);
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_updatePalette());
  }

  @override
  void didUpdateWidget(covariant AlbumBlurFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.id != widget.track?.id ||
        oldWidget.track?.coverUrl != widget.track?.coverUrl) {
      unawaited(_updatePalette());
    }
  }

  Future<void> _updatePalette() async {
    final int generation = ++_generation;
    final String? coverUrl = widget.track?.coverUrl;
    final List<Color>? mesh = await albumMeshColorsForCover(coverUrl);
    final Color? seed = await albumSeedForCover(coverUrl);
    if (!mounted || generation != _generation) return;
    widget.onSeed?.call(seed);
    setState(
      () => _colors = mesh ?? albumFlowColors(seed ?? kAlbumDefaultSeed),
    );
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
            if (widget.mode == LegacyBackgroundMode.solidColor)
              ColoredBox(
                color:
                    widget.solidColor ??
                    backgroundFromTheme(
                      Theme.of(context).colorScheme.primary,
                      Brightness.dark,
                    ),
              )
            else if (widget.mode == LegacyBackgroundMode.customImage)
              CustomImageBackdrop(
                path: widget.imagePath,
                pageColor: widget.pageColor,
              )
            else if (widget.mode != LegacyBackgroundMode.off)
              AlbumFlowBackground(
                colors: _colors,
                animated:
                    widget.animationsEnabled &&
                    widget.mode == LegacyBackgroundMode.nowPlayingDynamic,
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
