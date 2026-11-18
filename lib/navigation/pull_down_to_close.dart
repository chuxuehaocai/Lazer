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

class _PlayerPullDownRegionState extends State<PlayerPullDownRegion>
    with WidgetsBindingObserver {
  PlayerPullDown? _activePull;
  double _origin = 0;
  double _travel = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(PlayerPullDownRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        widget.pullDown != oldWidget.pullDown ||
        widget.travel != oldWidget.travel) {
      _end(0, cancel: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _end(0, cancel: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _end(0, cancel: true);
    super.dispose();
  }

  bool get _canStart =>
      _activePull == null &&
      widget.enabled &&
      widget.travel.isFinite &&
      widget.travel > 0 &&
      widget.pullDown.canStart;

  void _start(DragStartDetails details) {
    // The host may have opened a sheet since this pointer entered the arena.
    if (!_canStart) return;
    _activePull = widget.pullDown;
    _origin = details.globalPosition.dy;
    _travel = widget.travel;
    _activePull!.startPull();
  }

  void _update(DragUpdateDetails details) {
    final pull = _activePull;
    if (pull == null) return;
    // Global coordinates: the page slides under the finger while the pull
    // runs, so a local delta would cancel the movement out.
    final double pulled = (details.globalPosition.dy - _origin).clamp(
      -_travel,
      _travel,
    );
    pull.updatePull(pulled / _travel);
  }

  void _end(double velocity, {bool cancel = false}) {
    final pull = _activePull;
    if (pull == null) return;
    _activePull = null;
    if (cancel) {
      pull.cancelPull();
    } else {
      pull.endPull(velocity);
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
              recognizer.onlyAcceptDragOnThreshold = true;
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
  int? _pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    super.addAllowedPointer(event);
  }

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    _pointer = event.pointer;
    super.addAllowedPointerPanZoom(event);
  }

  @override
  void handleNonAllowedPointer(PointerDownEvent event) {
    // OneSequenceGestureRecognizer rejects every pending arena entry by
    // default. An extra finger must not reject the original finger's pull.
    if (_pointer == null) super.handleNonAllowedPointer(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancelled?.call();
    super.handleEvent(event);
  }

  @override
  bool isPointerAllowed(PointerEvent event) =>
      _pointer == null &&
      (canStart?.call() ?? false) &&
      super.isPointerAllowed(event);

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) =>
      _pointer == null &&
      (canStart?.call() ?? false) &&
      super.isPointerPanZoomAllowed(event);

  /// Only a downward drag belongs to the player. Returning false keeps this
  /// recognizer in the arena without accepting, which leaves taps, and the
  /// lyric viewport's own upward scrolling, to their recognizers.
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved > computeHitSlop(pointerDeviceKind, gestureSettings);
}
