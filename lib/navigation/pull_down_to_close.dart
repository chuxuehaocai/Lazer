import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Host side of the player's pull-down dismissal.
///
/// The player owns the gesture; the host owns the transition the pull drives,
/// so the page follows the finger instead of replaying a canned animation once
/// the gesture ends.
abstract class PlayerPullDown {
  /// Whether a new pull may take over the currently presented motion.
  bool get canStart;

  /// The finger has travelled far enough down to own the gesture.
  void startPull();

  /// Reports the finger's displacement since taking over, divided by the
  /// travel distance. Hosts apply it to their position at [startPull], so a
  /// running transition can be grabbed and reversed without a jump.
  void updatePull(double progress);

  /// Ends the gesture. [velocity] is positive when the finger moved downward.
  void endPull(double velocity);

  void cancelPull() => endPull(0);
}

/// An invisible strip that turns a downward drag into a pull on [pullDown].
///
/// Only pointers that land inside the strip are claimed, and only once the
/// drag heads down, so taps and upward lyric scrolls keep their own
/// recognizers. Place it above the page content in a stack: recognizers join
/// the gesture arena in hit-test order, and the higher entry answers first, so
/// a downward drag that starts over the lyrics still belongs to the player.
class PlayerPullDownRegion extends StatefulWidget {
  const PlayerPullDownRegion({
    super.key,
    required this.pullDown,
    required this.travel,
    this.enabled = true,
  });

  final PlayerPullDown pullDown;

  /// Logical pixels the player moves when the pull completes. Progress is the
  /// finger distance divided by this, so it must match the host's transition.
  final double travel;

  /// Whether the page itself accepts the gesture (no sheet, selection or
  /// dialog is holding the stage).
  final bool enabled;

  @override
  State<PlayerPullDownRegion> createState() => _PlayerPullDownRegionState();
}

class _PlayerPullDownRegionState extends State<PlayerPullDownRegion> {
  bool _pulling = false;
  double _origin = 0;

  bool get _canStart =>
      widget.enabled && widget.travel > 0 && widget.pullDown.canStart;

  void _start(DragStartDetails details) {
    _pulling = true;
    _origin = details.globalPosition.dy;
    widget.pullDown.startPull();
  }

  void _update(DragUpdateDetails details) {
    if (!_pulling) return;
    // Global coordinates: the page slides under the finger while the pull
    // runs, so a local delta would cancel the movement out.
    final double pulled = (details.globalPosition.dy - _origin).clamp(
      -widget.travel,
      widget.travel,
    );
    widget.pullDown.updatePull(pulled / widget.travel);
  }

  void _end(double velocity, {bool cancel = false}) {
    if (!_pulling) return;
    _pulling = false;
    if (cancel) {
      widget.pullDown.cancelPull();
    } else {
      widget.pullDown.endPull(velocity);
    }
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.translucent,
    excludeFromSemantics: true,
    gestures: <Type, GestureRecognizerFactory>{
      _PullDownDragRecognizer:
          GestureRecognizerFactoryWithHandlers<_PullDownDragRecognizer>(
            () => _PullDownDragRecognizer(debugOwner: this),
            (_PullDownDragRecognizer recognizer) {
              recognizer.dragStartBehavior = DragStartBehavior.down;
              recognizer.canStart = () => _canStart;
              recognizer.onStart = _start;
              recognizer.onUpdate = _update;
              recognizer.onEnd = (DragEndDetails details) {
                _end(details.velocity.pixelsPerSecond.dy);
              };
              recognizer.onCancel = () => _end(0, cancel: true);
              recognizer.onPointerCancelled = () => _end(0, cancel: true);
            },
          ),
    },
    child: const SizedBox.expand(),
  );
}

class _PullDownDragRecognizer extends VerticalDragGestureRecognizer {
  _PullDownDragRecognizer({super.debugOwner});

  bool Function()? canStart;
  VoidCallback? onPointerCancelled;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancelled?.call();
    super.handleEvent(event);
  }

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (canStart?.call() ?? false) && super.isPointerAllowed(event);

  /// Only a downward drag belongs to the player. Returning false keeps this
  /// recognizer in the arena without accepting, which leaves taps, and the
  /// lyric viewport's own upward scrolling, to their recognizers.
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved > computeHitSlop(pointerDeviceKind, gestureSettings);
}
