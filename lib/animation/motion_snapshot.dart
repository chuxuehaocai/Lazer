import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';

import '../widgets/cover_transition.dart';

/// Rasterize a page once while its outer transform is moving. Repainting every
/// blurred lyric row at every translated position defeats the raster cache.
class MotionSnapshot extends StatefulWidget {
  const MotionSnapshot({
    super.key,
    required this.animation,
    required this.child,
    this.snapshotForward = true,
    this.snapshotReverse = true,
  });
  final Animation<double> animation;
  final Widget child;

  /// Whether a forward run may replace the page with a cached raster.
  ///
  /// An incoming page must stay live: its first frame often holds a loading
  /// placeholder, and freezing that frame leaves the page apparently empty
  /// until the spring ends — at slow animation speeds for over a second.
  /// Outgoing pages still opt in because nobody needs to watch them repaint
  /// while they slide away.
  final bool snapshotForward;

  /// Whether a reverse run may replace the page with a cached raster. A page
  /// revealed by a closing motion (the shell under the player) must stay live
  /// for the same reason.
  final bool snapshotReverse;

  /// Refresh frozen transition pixels when asynchronous visible content arrives.
  static void invalidate(BuildContext context) {
    if (!context.mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => invalidate(context));
      return;
    }
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is SnapshotWidget) widget.controller.clear();
      return true;
    });
  }

  @override
  State<MotionSnapshot> createState() => _MotionSnapshotState();
}

class _MotionSnapshotState extends State<MotionSnapshot> {
  late final SnapshotController _snapshot = SnapshotController();
  bool _scrolling = false;

  void _status(AnimationStatus status) {
    final forward = status == AnimationStatus.forward && widget.snapshotForward;
    final reverse = status == AnimationStatus.reverse && widget.snapshotReverse;
    final moving = forward || reverse;
    if (!moving) {
      _scrolling = false;
      // Release the raster as soon as the motion ends. A parked page never
      // paints, so a kept raster would be reused verbatim when it comes back.
      _snapshot.clear();
    } else if (!_snapshot.allowSnapshotting) {
      // A page parked before this move may still hold its previous raster.
      // Offstage pages never repaint, so that image would otherwise be shown
      // for one frame when the page comes back — the returning home shelf
      // appeared twice, offset and dimmed, before this clear.
      _snapshot.clear();
    }
    _snapshot.allowSnapshotting = moving && !_scrolling;
  }

  bool _onScroll(ScrollNotification notification) {
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      // A returning page is already interactive while its spring settles.
      finishReturningCoverOnScroll(context);
      finishOpeningCoverOnScroll(context);
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
