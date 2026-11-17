import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../state/ui_preferences.dart';

/// A shared, aspect-preserving decode for the canvas and its crop preview.
/// A 48 MP photo must not pin a 192 MB texture behind every browsing page.
ImageProvider backgroundImageProvider(String path) => ResizeImage(
  FileImage(File(path)),
  width: 2048,
  height: 2048,
  policy: ResizeImagePolicy.fit,
);

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
        : Image(
            image: backgroundImageProvider(source),
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
      child: ClipRect(child: ColoredBox(color: pageColor, child: blurred)),
    );
  }
}
