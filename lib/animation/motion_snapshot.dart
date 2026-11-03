import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../widgets/cover_transition.dart';

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
  bool _scrolling = false;

  void _status(AnimationStatus status) {
    final moving =
        status == AnimationStatus.forward || status == AnimationStatus.reverse;
    if (!moving) _scrolling = false;
    _snapshot.allowSnapshotting = moving && !_scrolling;
  }

  bool _onScroll(ScrollNotification notification) {
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      // A returning page is already interactive while its spring settles.
      finishReturningCoverOnScroll(context);
      if (_snapshot.allowSnapshotting) {
        _scrolling = true;
        _snapshot.allowSnapshotting = false;
      }
    }
    return false;
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
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: SnapshotWidget(
          controller: _snapshot,
          mode: SnapshotMode.permissive,
          autoresize: true,
          child: RepaintBoundary(child: widget.child),
        ),
      );
}
