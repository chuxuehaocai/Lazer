import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../state/ui_preferences.dart';

/// Paints a selected image with the persisted crop, zoom and blur settings.
class CustomImageBackdrop extends StatelessWidget {
  const CustomImageBackdrop({
    super.key,
    required this.path,
    required this.pageColor,
    this.alignmentX = 0,
    this.alignmentY = 0,
    this.scale = 1,
    this.blurSigma = 0,
  });

  final String? path;
  final Color pageColor;
  final double alignmentX;
  final double alignmentY;
  final double scale;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final String? source = path;
    final Widget image = source == null || source.isEmpty
        ? const SizedBox.expand()
        : Image.file(
            File(source),
            fit: BoxFit.cover,
            alignment: Alignment(alignmentX, alignmentY),
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stack) =>
                    const SizedBox.expand(),
          );
    final Widget positioned = Transform.scale(
      scale: scale.clamp(kBackgroundImageScaleMin, kBackgroundImageScaleMax),
      alignment: Alignment(alignmentX, alignmentY),
      child: image,
    );
    final Widget blurred = blurSigma <= 0
        ? positioned
        : ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: blurSigma,
              sigmaY: blurSigma,
            ),
            child: positioned,
          );
    return RepaintBoundary(
      child: ColoredBox(color: pageColor, child: blurred),
    );
  }
}
