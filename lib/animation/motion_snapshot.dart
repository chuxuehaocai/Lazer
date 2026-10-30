import 'package:flutter/material.dart';

/// Rasterize a page once while its outer transform is moving. Repainting every
/// blurred lyric row at every translated position defeats the raster cache.
class MotionSnapshot extends StatefulWidget {
  const MotionSnapshot({
    super.key,
    required this.animation,
    required this.child,
  });
  final Animation<double> animation;
  final Widget child;

  @override
  State<MotionSnapshot> createState() => _MotionSnapshotState();
}

class _MotionSnapshotState extends State<MotionSnapshot> {
  late final SnapshotController _snapshot = SnapshotController();

  void _status(AnimationStatus status) {
    _snapshot.allowSnapshotting =
        status == AnimationStatus.forward || status == AnimationStatus.reverse;
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
    _status(widget.animation.status);
  }

  @override
  void didUpdateWidget(covariant MotionSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_status);
      widget.animation.addStatusListener(_status);
      _status(widget.animation.status);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _snapshot,
    mode: SnapshotMode.permissive,
    autoresize: true,
    child: RepaintBoundary(child: widget.child),
  );
}
