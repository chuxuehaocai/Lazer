import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Blends the captured source card into a live cover without stretching either.
///
/// The enclosing Flow moves a fixed square onto [frameRect]. This surface
/// cancels that nonuniform scale while painting, then fits both artworks into
/// the resulting frame with their original proportions. Only paint listens to
/// [animation]; the live cover keeps one layout throughout the flight.
///
/// The caller owns [source] and must keep it alive until this surface detaches.
class CoverMorphSurface extends SingleChildRenderObjectWidget {
  const CoverMorphSurface({
    super.key,
    required this.animation,
    required this.source,
    required this.frameRect,
    required this.fromBlend,
    required this.toBlend,
    required this.sourceRadius,
    required this.targetRadius,
    required super.child,
  });

  final Animation<double> animation;
  final ui.Image source;
  final Rect Function() frameRect;
  final double fromBlend;
  final double toBlend;
  final double sourceRadius;
  final double targetRadius;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCoverMorph(
    animation,
    source,
    frameRect,
    fromBlend,
    toBlend,
    sourceRadius,
    targetRadius,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderCoverMorph)
      ..animation = animation
      ..source = source
      ..frameRect = frameRect
      ..fromBlend = fromBlend
      ..toBlend = toBlend
      ..sourceRadius = sourceRadius
      ..targetRadius = targetRadius;
  }
}

class _RenderCoverMorph extends RenderProxyBox {
  _RenderCoverMorph(
    this._animation,
    this._source,
    this._frameRect,
    this._fromBlend,
    this._toBlend,
    this._sourceRadius,
    this._targetRadius,
  );

  Animation<double> _animation;
  ui.Image _source;
  Rect Function() _frameRect;
  double _fromBlend;
  double _toBlend;
  double _sourceRadius;
  double _targetRadius;

  final LayerHandle<TransformLayer> _frameLayer = LayerHandle<TransformLayer>();
  final LayerHandle<ClipRRectLayer> _clipLayer = LayerHandle<ClipRRectLayer>();
  final LayerHandle<TransformLayer> _coverLayer = LayerHandle<TransformLayer>();

  set animation(Animation<double> value) {
    if (identical(_animation, value)) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  set source(ui.Image value) {
    if (identical(_source, value)) return;
    _source = value;
    markNeedsPaint();
  }

  set frameRect(Rect Function() value) {
    if (_frameRect == value) return;
    _frameRect = value;
    markNeedsPaint();
  }

  set fromBlend(double value) {
    if (_fromBlend == value) return;
    _fromBlend = value;
    markNeedsPaint();
  }

  set toBlend(double value) {
    if (_toBlend == value) return;
    _toBlend = value;
    markNeedsPaint();
  }

  set sourceRadius(double value) {
    if (_sourceRadius == value) return;
    _sourceRadius = value;
    markNeedsPaint();
  }

  set targetRadius(double value) {
    if (_targetRadius == value) return;
    _targetRadius = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _frameLayer.layer = null;
    _clipLayer.layer = null;
    _coverLayer.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final frame = _frameRect();
    if (size.isEmpty || frame.isEmpty || !frame.size.isFinite) return;
    final blend = ui
        .lerpDouble(_fromBlend, _toBlend, _animation.value.clamp(0.0, 1.0))!
        .clamp(0.0, 1.0);
    final radius = math.max(
      0.0,
      ui.lerpDouble(_sourceRadius, _targetRadius, blend)!,
    );

    // Flow stretches this square by frame.width / size.width and its height
    // equivalent. In this coordinate space those scales cancel, so a circular
    // corner here is the compensated elliptical corner in the square's space.
    final inverse = Matrix4.diagonal3Values(
      size.width / frame.width,
      size.height / frame.height,
      1,
    );
    _frameLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      inverse,
      (frameContext, frameOffset) {
        final bounds = Offset.zero & frame.size;
        _clipLayer.layer = frameContext.pushClipRRect(
          needsCompositing,
          frameOffset,
          bounds,
          RRect.fromRectAndRadius(bounds, Radius.circular(radius)),
          (contentContext, contentOffset) {
            final cover = child;
            if (cover != null && !cover.size.isEmpty) {
              final scale = math.max(
                frame.width / cover.size.width,
                frame.height / cover.size.height,
              );
              final transform = Matrix4.diagonal3Values(scale, scale, 1)
                ..setTranslationRaw(
                  (frame.width - cover.size.width * scale) / 2,
                  (frame.height - cover.size.height * scale) / 2,
                  0,
                );
              _coverLayer.layer = contentContext.pushTransform(
                needsCompositing,
                contentOffset,
                transform,
                (coverContext, coverOffset) =>
                    coverContext.paintChild(cover, coverOffset),
                oldLayer: _coverLayer.layer,
              );
            } else {
              _coverLayer.layer = null;
            }
            // A full-opacity target underneath a fading source keeps the
            // composition opaque, including at the middle of the dissolve.
            if (blend < 1) {
              paintImage(
                canvas: contentContext.canvas,
                rect: bounds.shift(contentOffset),
                image: _source,
                fit: BoxFit.cover,
                opacity: 1 - blend,
                filterQuality: FilterQuality.medium,
              );
            }
          },
          oldLayer: _clipLayer.layer,
        );
      },
      oldLayer: _frameLayer.layer,
    );
  }
}
