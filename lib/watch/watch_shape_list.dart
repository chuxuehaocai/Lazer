import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Geometry of the physical display, rather than a fixed inset rectangle.
/// Every visible row fits the narrowest ellipse chord across its height.
class WatchDisplayGeometry {
  const WatchDisplayGeometry(this.size, {this.margin = 3});

  final Size size;
  final double margin;

  double widthForBand(double top, double bottom) {
    final rx = math.max(0.0, size.width / 2 - margin);
    final ry = math.max(0.0, size.height / 2 - margin);
    if (rx == 0 || ry == 0) return 0;
    final farthest = math.max(
      (top - size.height / 2).abs(),
      (bottom - size.height / 2).abs(),
    );
    if (farthest >= ry) return 0;
    return 2 * rx * math.sqrt(1 - math.pow(farthest / ry, 2));
  }
}

/// A lazy list whose mounted rows follow a round display's outline.
/// Only scrolling changes row insets; no animation controller or text
/// measurement runs between gestures. Square displays use the full width.
class WatchShapeList extends StatefulWidget {
  const WatchShapeList({
    super.key,
    required this.round,
    required this.displaySize,
    required this.top,
    required this.itemCount,
    required this.itemBuilder,
    required this.storageKey,
    this.itemExtent = 56,
  });

  final bool round;
  final Size displaySize;
  final double top;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final String storageKey;
  final double itemExtent;

  @override
  State<WatchShapeList> createState() => _WatchShapeListState();
}

class _WatchShapeListState extends State<WatchShapeList> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final geometry = WatchDisplayGeometry(widget.displaySize);
    final end = widget.round ? widget.displaySize.height * .36 : 12.0;
    return ListView.builder(
      key: PageStorageKey(widget.storageKey),
      controller: _scroll,
      padding: EdgeInsets.only(top: 2, bottom: end),
      itemCount: widget.itemCount,
      itemExtent: widget.itemExtent,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemBuilder: (context, index) {
        final child = widget.itemBuilder(context, index);
        if (!widget.round) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: child,
          );
        }
        return AnimatedBuilder(
          animation: _scroll,
          child: child,
          builder: (context, child) {
            final offset = _scroll.hasClients ? _scroll.offset : 0.0;
            final top = widget.top + 2 + index * widget.itemExtent - offset + 3;
            final width = geometry.widthForBand(
              top,
              top + widget.itemExtent - 6,
            );
            // At the poles there is no room for a usable control. Reserve its
            // row until it scrolls into the display; do not squeeze inputs or
            // leave invisible buttons outside the circular touch surface.
            if (width < 76) return const SizedBox.shrink();
            return Center(
              child: SizedBox(
                width: width,
                height: widget.itemExtent - 6,
                child: child,
              ),
            );
          },
        );
      },
    );
  }
}
