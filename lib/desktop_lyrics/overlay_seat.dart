import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

/// Decides where a remembered floating-lyrics seat may actually be placed.
///
/// Pulled out of `lyrics_overlay.dart` so the geometry can be tested without
/// mounting a second window: it is the only part of the restore path that can
/// silently put the overlay somewhere invisible.
///
/// The stored point was chosen while some set of displays was attached. Undock a
/// laptop, unplug the monitor the lyrics were parked on, or drop the resolution,
/// and the same coordinates land off-screen — the floating overlay has no title
/// bar, so a seat outside every display cannot be dragged back. Hence: keep the
/// seat when the whole window still fits a display, otherwise slide it onto the
/// nearest visible area.
Future<Offset> reachableFloatingSeat(
  Offset seat,
  Size size, {
  Future<List<Display>> Function()? displays,
}) async {
  try {
    final List<Display> attached =
        await (displays ?? screenRetriever.getAllDisplays)();
    final List<Rect> areas = <Rect>[
      for (final Display display in attached)
        if (visibleAreaOf(display) case final Rect area) area,
    ];
    if (areas.isEmpty) return seat;
    final Rect window = seat & size;
    for (final Rect area in areas) {
      if (area.contains(window.topLeft) && area.contains(window.bottomRight)) {
        return seat;
      }
    }
    // Nothing holds the whole window: slide it into the nearest area, keeping it
    // fully on that display when the window is smaller than the display. A window
    // larger than every display is aligned to that display's origin instead of
    // being pushed off the opposite edge by the clamp.
    Rect nearest = areas.first;
    double nearestDistance = double.infinity;
    for (final Rect area in areas) {
      final double distance = _distanceSquared(area, seat);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = area;
      }
    }
    return Offset(
      _clampAxis(seat.dx, nearest.left, nearest.right, size.width),
      _clampAxis(seat.dy, nearest.top, nearest.bottom, size.height),
    );
  } catch (_) {
    // No platform channel (tests, an unsupported platform): the stored seat still
    // beats re-centring, which is the behaviour this replaced.
    return seat;
  }
}

/// The part of a display a window may occupy, in logical pixels.
///
/// [Display.visiblePosition] and [Display.visibleSize] are optional in the
/// platform interface; a display that does not report them contributes nothing,
/// because a guessed rectangle is how a window ends up "placed" off-screen.
Rect? visibleAreaOf(Display display) {
  final Offset? origin = display.visiblePosition;
  final Size extent = display.visibleSize ?? display.size;
  if (origin == null) return null;
  if (!origin.dx.isFinite || !origin.dy.isFinite) return null;
  if (!extent.width.isFinite || !extent.height.isFinite) return null;
  if (extent.width <= 0 || extent.height <= 0) return null;
  return Rect.fromLTWH(origin.dx, origin.dy, extent.width, extent.height);
}

double _clampAxis(double value, double start, double end, double extent) {
  // `end - extent` can sit before `start` when the window is larger than the
  // display; in that case only the start edge is honoured.
  final double highest = end - extent > start ? end - extent : start;
  return value.clamp(start, highest);
}

/// How far a point sits outside [area]; zero while it is inside.
double _distanceSquared(Rect area, Offset point) {
  final double dx = point.dx < area.left
      ? area.left - point.dx
      : point.dx > area.right
      ? point.dx - area.right
      : 0;
  final double dy = point.dy < area.top
      ? area.top - point.dy
      : point.dy > area.bottom
      ? point.dy - area.bottom
      : 0;
  return dx * dx + dy * dy;
}
