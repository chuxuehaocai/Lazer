import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../animation/apple_spring.dart';
import 'cover_morph_surface.dart';

const _coverSpring = AppleSpring(duration: Duration(milliseconds: 420));

class _CoverSnapshot {
  _CoverSnapshot(this.image) {
    _liveSnapshots++;
  }
  final ui.Image image;
  int _references = 1;
  _CoverSnapshot retain() {
    assert(_references > 0);
    _references++;
    return this;
  }

  void release() {
    assert(_references > 0);
    if (--_references == 0) {
      image.dispose();
      _liveSnapshots--;
    }
  }
}

int _liveSnapshots = 0;
@visibleForTesting
int get debugCoverSnapshotCount => _liveSnapshots;

class _CoverCaptureBoundary extends RepaintBoundary {
  const _CoverCaptureBoundary({super.key, required super.child});
  @override
  _RenderCoverCaptureBoundary createRenderObject(BuildContext context) =>
      _RenderCoverCaptureBoundary();
}

class _RenderCoverCaptureBoundary extends RenderRepaintBoundary {
  ui.Image? captureLastPaint(double pixelRatio) {
    final painted = layer;
    if (painted is! OffsetLayer || !hasSize || size.isEmpty) return null;
    // A tap can mark the card dirty before navigation. Capture its last
    // visible layer, rather than requiring an extra paint before opening.
    return painted.toImageSync(Offset.zero & size, pixelRatio: pixelRatio);
  }
}

class _CoverOrigin {
  const _CoverOrigin(
    this.identity,
    this.rect,
    this.sourceKey,
    this.recordedAt,
    this.snapshot,
    this.radius, [
    this.presentation,
  ]);
  final String identity;
  final Rect rect;
  final GlobalKey sourceKey;
  final DateTime recordedAt;
  final _CoverSnapshot? snapshot;
  final double radius;
  final _CoverPresentation? presentation;
}

_CoverOrigin? _pendingCover;
final Map<String, _CoverTransitionTargetState> _targets =
    <String, _CoverTransitionTargetState>{};
final Map<String, Set<GlobalKey>> _sourceKeys = <String, Set<GlobalKey>>{};
final Set<GlobalKey> _hiddenSources = <GlobalKey>{};
final Map<GlobalKey, ValueNotifier<bool>> _sourceVisibility =
    <GlobalKey, ValueNotifier<bool>>{};
final Map<GlobalKey, _CoverTransitionSourceState> _sourceStates = {};
final Map<GlobalKey, bool> _pendingVisibility = <GlobalKey, bool>{};
bool _visibilityScheduled = false;
OverlayEntry? _returnFlight;
GlobalKey? _returnSource;
int _returnGeneration = 0;
_CoverSnapshot? _returnSnapshot;
String? _returnIdentity;
_CoverPresentation? _returnPresentation;
_CoverFlightHandle? _returnHandle;
final List<OverlayEntry> _handoffFlights = [];
String? _handoffIdentity;

void _removeHandoffFlights([String? identity]) {
  if (identity != null && identity != _handoffIdentity) return;
  final flights = _handoffFlights.toList();
  _handoffFlights.clear();
  _handoffIdentity = null;
  for (final flight in flights) {
    flight.remove();
    flight.dispose();
  }
}

void _hideSource(GlobalKey key, bool hidden) {
  _pendingVisibility[key] = hidden;
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    if (_visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      final updates = Map<GlobalKey, bool>.of(_pendingVisibility);
      _pendingVisibility.clear();
      for (final entry in updates.entries) {
        _applySourceVisibility(entry.key, entry.value);
      }
    });
  } else {
    _pendingVisibility.remove(key);
    _applySourceVisibility(key, hidden);
  }
}

void _applySourceVisibility(GlobalKey key, bool hidden) {
  if (hidden && key.currentContext == null) return;
  final changed = hidden ? _hiddenSources.add(key) : _hiddenSources.remove(key);
  if (changed) {
    _sourceVisibility[key]?.value = hidden;
    if (_sourceStates[key]?._active != false) {
      _refreshSnapshots(key.currentContext);
    }
  }
}

void _refreshSnapshots(BuildContext? context) {
  // Page transforms can retain a raster containing this cover's old hidden
  // state. Invalidate once at handoff so shorter cover springs never reveal a
  // hole while the enclosing page is still finishing its own spring.
  if (context == null || !context.mounted) return;
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) _refreshSnapshots(context);
    });
    return;
  }
  context.visitAncestorElements((element) {
    final ancestor = element.widget;
    if (ancestor is SnapshotWidget) ancestor.controller.clear();
    return true;
  });
}

/// A source keeps its layout while its artwork travels in the root overlay.
class CoverTransitionSource extends StatefulWidget {
  const CoverTransitionSource({
    required GlobalKey super.key,
    required this.child,
    this.identity,
    this.morphArtwork = false,
    this.radius = 14,
  });
  final Widget child;
  final String? identity;

  /// Composite home cards dissolve their original pixels into the detail
  /// artwork instead of replacing a mosaic/logo at the first flight frame.
  final bool morphArtwork;
  final double radius;

  @override
  State<CoverTransitionSource> createState() => _CoverTransitionSourceState();
}

class _CoverTransitionSourceState extends State<CoverTransitionSource> {
  final GlobalKey _capture = GlobalKey();
  bool _active = true;
  late final ValueNotifier<bool> _hidden = ValueNotifier<bool>(
    _hiddenSources.contains(widget.key),
  );
  void _register() {
    final identity = widget.identity;
    if (identity != null) {
      (_sourceKeys[identity] ??= <GlobalKey>{}).add(widget.key! as GlobalKey);
    }
  }

  void _unregister(CoverTransitionSource source) {
    final keys = _sourceKeys[source.identity];
    keys?.remove(source.key);
    if (keys?.isEmpty ?? false) _sourceKeys.remove(source.identity);
  }

  @override
  void initState() {
    super.initState();
    _sourceVisibility[widget.key! as GlobalKey] = _hidden;
    _sourceStates[widget.key! as GlobalKey] = this;
    _register();
  }

  @override
  void didUpdateWidget(covariant CoverTransitionSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _unregister(oldWidget);
      _register();
    }
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    _unregister(widget);
    if (_pendingCover?.sourceKey == widget.key) {
      _pendingCover?.snapshot?.release();
      _pendingCover = null;
    }
    _sourceVisibility.remove(widget.key);
    _sourceStates.remove(widget.key);
    _hiddenSources.remove(widget.key);
    _pendingVisibility.remove(widget.key);
    _hidden.dispose();
    super.dispose();
  }

  _CoverSnapshot? _snapshot() {
    if (!widget.morphArtwork) return null;
    final boundary = _capture.currentContext?.findRenderObject();
    if (boundary is! _RenderCoverCaptureBoundary ||
        !boundary.hasSize ||
        boundary.size.isEmpty) {
      return null;
    }
    // Record only the already painted card, without readback or rebuilding its
    // mosaic. Limit its texture to 1024 px so this cannot become a page capture.
    final ratio = math.min(
      math.min(MediaQuery.devicePixelRatioOf(context), 2.0),
      1024 / boundary.size.longestSide,
    );
    try {
      final image = boundary.captureLastPaint(ratio);
      return image == null ? null : _CoverSnapshot(image);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _hidden,
    child: _CoverCaptureBoundary(key: _capture, child: widget.child),
    builder: (context, hidden, child) =>
        Opacity(opacity: hidden ? 0 : 1, child: child),
  );
}

GlobalKey? _liveSourceKey(_CoverOrigin origin) {
  if (_sourceBox(origin.sourceKey) != null) return origin.sourceKey;
  // A responsive rebuild can replace a shelf's local key. Measure its newly
  // mounted card instead of replaying the old screen position or DPI.
  GlobalKey? best;
  var distance = double.infinity;
  for (final key in _sourceKeys[origin.identity] ?? <GlobalKey>{}) {
    final box = _sourceBox(key);
    if (box == null) continue;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    final delta = (center - origin.rect.center).distanceSquared;
    if (delta < distance) {
      distance = delta;
      best = key;
    }
  }
  return best;
}

RenderBox? _sourceBox(GlobalKey key) {
  // Responsive shelf rebuilds can deactivate an old key before disposing it.
  // Its context is still mounted, but it no longer owns a measurable surface.
  if (_sourceStates[key]?._active == false) return null;
  final box = key.currentContext?.findRenderObject();
  return box is RenderBox && box.attached && box.hasSize ? box : null;
}

void _removeReturnFlight() {
  _returnGeneration++;
  _returnFlight?.remove();
  _returnFlight?.dispose();
  _returnFlight = null;
  _returnSnapshot?.release();
  _returnSnapshot = null;
  _returnIdentity = null;
  _returnPresentation = null;
  _returnHandle = null;
  final source = _returnSource;
  _returnSource = null;
  if (source != null) _hideSource(source, false);
}

/// Cancels visual work when the shell changes account, section, or closes.
void cancelCoverTransitions() {
  _pendingCover?.snapshot?.release();
  _pendingCover = null;
  _removeHandoffFlights();
  _removeReturnFlight();
  for (final target in _targets.values.toList()) {
    target._cancelFlight();
  }
  for (final key in {..._hiddenSources, ..._pendingVisibility.keys}) {
    _hideSource(key, false);
  }
}

/// Called before the detail leaves, while its current bounds are still valid.
/// The destination is the live retained card, including its restored scrolling.
bool returnCoverTransition(String identity) =>
    _targets[identity]?._returnToSource() ?? false;

/// Records the exact artwork bounds before the content pane changes. Unlike a
/// route Hero, this also works with the shell's in-place page transitions.
void rememberCoverTransition(String identity, GlobalKey coverKey) {
  final box = coverKey.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
  // Reopening the same card reverses its currently presented flight. Retain
  // its pixels before cancellation releases the global return ownership.
  final presentation = _returnIdentity == identity ? _returnPresentation : null;
  final snapshot = presentation == null ? null : _returnSnapshot?.retain();
  final handoff = presentation == null ? null : _returnFlight;
  if (handoff != null) {
    // Keep the last returning pixels until the replacement overlay paints.
    // Its clock freezes at the same presentation that the new spring inherits.
    _returnHandle?.hold();
    _returnFlight = null;
  }
  cancelCoverTransitions();
  if (handoff != null) {
    _handoffFlights.add(handoff);
    _handoffIdentity = identity;
  }
  final reduced =
      MediaQuery.maybeOf(coverKey.currentContext!)?.disableAnimations ?? false;
  final source = _sourceStates[coverKey];
  _pendingCover = _CoverOrigin(
    identity,
    presentation?.rect ??
        Rect.fromPoints(
          box.localToGlobal(Offset.zero),
          box.localToGlobal(box.size.bottomRight(Offset.zero)),
        ),
    coverKey,
    DateTime.now(),
    reduced ? null : snapshot ?? source?._snapshot(),
    source?.widget.radius ?? 14,
    presentation,
  );
  if (reduced) snapshot?.release();
  // Keep the source visible until the overlay flight has been inserted. Hiding
  // it here leaves one frame with neither the source nor the flight painted,
  // which reads as a flash when a retained page switch begins.
  // A quick reopen can reactivate the same detail slot before its fade-out
  // disposes it. That state still needs to consume the new source and fly.
  final target = _targets[identity];
  if (target != null && target.mounted) {
    target._restartPendingFlight();
  }
}

/// Flies artwork from the tapped card to its final position in a detail page.
/// The destination is remeasured during the flight because the enclosing page
/// can still be moving in the shell's slide transition.
class CoverTransitionTarget extends StatefulWidget {
  const CoverTransitionTarget({
    super.key,
    required this.identity,
    required this.size,
    required this.child,
    this.radius = 14,
  });

  final String identity;
  final double size;
  final double radius;
  final Widget child;

  @override
  State<CoverTransitionTarget> createState() => _CoverTransitionTargetState();
}

class _CoverTransitionTargetState extends State<CoverTransitionTarget> {
  final GlobalKey _destination = GlobalKey();
  OverlayEntry? _flight;
  bool _flying = false;
  int _generation = 0;
  _CoverOrigin? _origin;
  Rect? _flightRect;
  double _flightBlend = 1;
  _CoverPresentation? _flightPresentation;
  bool _returning = false;

  void _restartPendingFlight() => setState(_beginPendingFlight);

  @override
  void initState() {
    super.initState();
    _targets[widget.identity] = this;
    _beginPendingFlight();
  }

  @override
  void didUpdateWidget(covariant CoverTransitionTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      if (_targets[oldWidget.identity] == this) {
        _targets.remove(oldWidget.identity);
      }
      _targets[widget.identity] = this;
      if (_origin != null) _hideSource(_origin!.sourceKey, false);
      _removeFlight();
      _forgetOrigin();
      _flying = false;
      _beginPendingFlight();
    }
  }

  void _beginPendingFlight() {
    final generation = ++_generation;
    final origin = _pendingCover;
    if (origin == null || origin.identity != widget.identity) return;
    _returning = false;
    _pendingCover = null;
    _forgetOrigin();
    _origin = origin;
    if (DateTime.now().difference(origin.recordedAt).inMilliseconds > 1200) {
      _removeHandoffFlights(widget.identity);
      _hideSource(origin.sourceKey, false);
      _forgetOrigin();
      return;
    }
    _flying = true;
    _flightBlend = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_flying || generation != _generation) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      final overlayBox = overlay?.context.findRenderObject();
      if (overlay == null ||
          overlayBox is! RenderBox ||
          MediaQuery.disableAnimationsOf(context)) {
        _removeHandoffFlights(widget.identity);
        setState(() => _flying = false);
        _hideSource(origin.sourceKey, false);
        return;
      }
      final start = Rect.fromPoints(
        overlayBox.globalToLocal(origin.rect.topLeft),
        overlayBox.globalToLocal(origin.rect.bottomRight),
      );
      Rect? destinationRect() {
        if (!mounted || !overlayBox.attached) return null;
        final target = _destination.currentContext?.findRenderObject();
        if (target is! RenderBox || !target.attached || !target.hasSize) {
          return null;
        }
        return Rect.fromPoints(
          overlayBox.globalToLocal(target.localToGlobal(Offset.zero)),
          overlayBox.globalToLocal(
            target.localToGlobal(target.size.bottomRight(Offset.zero)),
          ),
        );
      }

      // Capture themes and build the cover once. Its fixed layout is retained
      // while Flow only updates the layer's paint transform on each frame.
      final artwork = InheritedTheme.captureAll(
        context,
        RepaintBoundary(
          key: const ValueKey<String>('cover-transition-flight'),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: widget.child,
          ),
        ),
      );
      _flight = OverlayEntry(
        builder: (_) => Positioned.fill(
          child: _CoverFlight(
            start: start,
            initial: origin.presentation?.transformed(overlayBox.globalToLocal),
            destination: destinationRect,
            edge: widget.size,
            snapshot: origin.snapshot,
            sourceRadius: origin.radius,
            targetRadius: widget.radius,
            onRect: (rect) => _flightRect = rect,
            onBlend: (blend) => _flightBlend = blend,
            onPresentation: (presentation) =>
                _flightPresentation = presentation,
            onComplete: () {
              if (!mounted || generation != _generation) return;
              _removeFlight();
              _flightRect = null;
              _flightBlend = 1;
              _flightPresentation = null;
              _hideSource(origin.sourceKey, false);
              setState(() => _flying = false);
              _refreshSnapshots(context);
            },
            child: artwork,
          ),
        ),
      );
      overlay.insert(_flight!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) {
          _removeHandoffFlights(widget.identity);
        }
      });
      _hideSource(origin.sourceKey, true);
      _refreshSnapshots(context);
    });
  }

  void _removeFlight() {
    _flight?.remove();
    _flight?.dispose();
    _flight = null;
  }

  void _forgetOrigin() {
    _origin?.snapshot?.release();
    _origin = null;
  }

  void _cancelFlight() {
    _generation++;
    _removeFlight();
    _removeHandoffFlights(widget.identity);
    _flightRect = null;
    _flightBlend = 1;
    _flightPresentation = null;
    if (_origin != null) _hideSource(_origin!.sourceKey, false);
    _forgetOrigin();
    if (mounted && _flying) setState(() => _flying = false);
    if (mounted) _refreshSnapshots(context);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _flying) {
      _cancelFlight();
    }
  }

  bool _returnToSource() {
    final origin = _origin;
    final sourceKey = origin == null ? null : _liveSourceKey(origin);
    final source = sourceKey == null ? null : _sourceBox(sourceKey);
    final target = _destination.currentContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final overlayBox = overlay?.context.findRenderObject();
    if (origin == null ||
        sourceKey == null ||
        source is! RenderBox ||
        !source.attached ||
        target is! RenderBox ||
        !target.hasSize ||
        overlay == null ||
        overlayBox is! RenderBox ||
        MediaQuery.disableAnimationsOf(context)) {
      _cancelFlight();
      return false;
    }
    final start =
        _flightRect ??
        Rect.fromPoints(
          overlayBox.globalToLocal(
            _flying ? origin.rect.topLeft : target.localToGlobal(Offset.zero),
          ),
          overlayBox.globalToLocal(
            _flying
                ? origin.rect.bottomRight
                : target.localToGlobal(target.size.bottomRight(Offset.zero)),
          ),
        );
    final initial =
        _flightPresentation ??
        _CoverPresentation(start, Rect.zero, _flightBlend, 0);
    _generation++;
    _removeFlight();
    _flightRect = null;
    _removeReturnFlight();
    _returnSnapshot = origin.snapshot?.retain();
    final snapshot = _returnSnapshot;
    final fromBlend = _flightBlend;
    _hideSource(sourceKey, true);
    _returnSource = sourceKey;
    _returnIdentity = widget.identity;
    _returnPresentation = initial.transformed(overlayBox.localToGlobal);
    final handle = _returnHandle = _CoverFlightHandle();
    _returning = true;
    setState(() => _flying = true);
    _refreshSnapshots(context);
    final generation = _returnGeneration;
    final edge = widget.size;
    final artwork = InheritedTheme.captureAll(
      context,
      RepaintBoundary(
        key: const ValueKey<String>('cover-transition-return-flight'),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: widget.child,
        ),
      ),
    );
    var currentSource = sourceKey;
    Rect? lastDestination;
    Rect? destination() {
      if (_sourceBox(currentSource) == null) {
        final replacement = _liveSourceKey(origin);
        if (replacement != null && replacement != currentSource) {
          _hideSource(currentSource, false);
          currentSource = replacement;
          _hideSource(currentSource, true);
          _returnSource = currentSource;
        }
      }
      final box = _sourceBox(currentSource);
      if (box is! RenderBox ||
          !box.attached ||
          !box.hasSize ||
          !overlayBox.attached) {
        return lastDestination;
      }
      return lastDestination = Rect.fromPoints(
        overlayBox.globalToLocal(box.localToGlobal(Offset.zero)),
        overlayBox.globalToLocal(
          box.localToGlobal(box.size.bottomRight(Offset.zero)),
        ),
      );
    }

    // Insert before the same frame that hides the detail cover. Destination
    // reads happen during paint, after the retained shelf restores its layout.
    _returnFlight = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: _CoverFlight(
          handle: handle,
          start: start,
          initial: initial,
          destination: destination,
          edge: edge,
          snapshot: snapshot,
          sourceRadius: origin.radius,
          targetRadius: widget.radius,
          fromBlend: fromBlend,
          toBlend: 0,
          onPresentation: (presentation) {
            _returnPresentation = presentation.transformed(
              overlayBox.localToGlobal,
            );
          },
          onComplete: () {
            if (generation != _returnGeneration) return;
            _removeReturnFlight();
            _hideSource(currentSource, false);
            if (mounted) setState(() => _flying = false);
          },
          child: artwork,
        ),
      ),
    );
    overlay.insert(_returnFlight!);
    _removeHandoffFlights(widget.identity);
    return true;
  }

  @override
  void dispose() {
    _generation++;
    _removeFlight();
    if (_origin != null) _removeHandoffFlights(widget.identity);
    if (!_returning && _origin != null) _hideSource(_origin!.sourceKey, false);
    _forgetOrigin();
    if (_targets[widget.identity] == this) _targets.remove(widget.identity);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: _destination,
    dimension: widget.size,
    child: Opacity(opacity: _flying ? 0 : 1, child: widget.child),
  );
}

/// The root overlay owns the ticker: the incoming page intentionally mutes
/// its own tickers until its transition ends, but artwork must fly meanwhile.
class _CoverFlightHandle {
  _CoverFlightState? _state;
  bool _held = false;
  void hold() {
    _held = true;
    _state?._controller.stop();
  }
}

class _CoverFlight extends StatefulWidget {
  const _CoverFlight({
    required this.start,
    required this.destination,
    required this.edge,
    required this.onComplete,
    required this.child,
    this.onRect,
    this.snapshot,
    this.sourceRadius = 14,
    this.targetRadius = 14,
    this.fromBlend = 0,
    this.toBlend = 1,
    this.onBlend,
    this.initial,
    this.onPresentation,
    this.handle,
  });

  final Rect start;
  final Rect? Function() destination;
  final double edge;
  final VoidCallback onComplete;
  final Widget child;
  final ValueChanged<Rect>? onRect;
  final _CoverSnapshot? snapshot;
  final double sourceRadius, targetRadius;
  final double fromBlend, toBlend;
  final ValueChanged<double>? onBlend;
  final _CoverPresentation? initial;
  final ValueChanged<_CoverPresentation>? onPresentation;
  final _CoverFlightHandle? handle;

  @override
  State<_CoverFlight> createState() => _CoverFlightState();
}

class _CoverFlightState extends State<_CoverFlight>
    with SingleTickerProviderStateMixin {
  _CoverSnapshot? _snapshot;
  late final _CoverPhysics _physics;
  late final Animation<double> _blend;
  late final AnimationController _controller =
      AnimationController.unbounded(vsync: this)..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onComplete();
      });

  @override
  void initState() {
    super.initState();
    widget.handle?._state = this;
    // OverlayEntry.remove may defer unmounting until the next frame. Keep
    // pixels alive until this flight actually detaches, even if its page or
    // the global return slot has already released their own references.
    _snapshot = widget.snapshot?.retain();
    _physics = _CoverPhysics(
      widget.initial ??
          _CoverPresentation(widget.start, Rect.zero, widget.fromBlend, 0),
      widget.destination,
      widget.toBlend,
    );
    _blend = _CoverBlend(
      _controller,
      () => _physics.presentation(_controller.value).blend,
    );
    if (!(widget.handle?._held ?? false)) _controller.animateWith(_physics);
  }

  @override
  void didUpdateWidget(_CoverFlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot) {
      final previous = _snapshot;
      _snapshot = widget.snapshot?.retain();
      previous?.release();
    }
  }

  @override
  void dispose() {
    if (widget.handle?._state == this) widget.handle?._state = null;
    _controller.dispose();
    _snapshot?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: Flow(
        clipBehavior: Clip.none,
        delegate: _CoverFlightDelegate(
          animation: _controller,
          start: widget.start,
          destination: widget.destination,
          edge: widget.edge,
          onRect: widget.onRect,
          fromBlend: widget.fromBlend,
          toBlend: widget.toBlend,
          onBlend: widget.onBlend,
          presentation: () => _physics.presentation(_controller.value),
          onPresentation: widget.onPresentation,
        ),
        children: [
          if (_snapshot case final snapshot?)
            CoverMorphSurface(
              animation: _blend,
              source: snapshot.image,
              frameRect: () => _physics.presentation(_controller.value).rect,
              fromBlend: 0,
              toBlend: 1,
              sourceRadius: widget.sourceRadius,
              targetRadius: widget.targetRadius,
              child: widget.child,
            )
          else
            widget.child,
        ],
      ),
    ),
  );
}

class _CoverFlightDelegate extends FlowDelegate {
  _CoverFlightDelegate({
    required this.animation,
    required this.start,
    required this.destination,
    required this.edge,
    this.onRect,
    this.fromBlend = 0,
    this.toBlend = 1,
    this.onBlend,
    required this.presentation,
    this.onPresentation,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Rect start;
  final Rect? Function() destination;
  final double edge;
  final ValueChanged<Rect>? onRect;
  final double fromBlend, toBlend;
  final ValueChanged<double>? onBlend;
  final _CoverPresentation Function() presentation;
  final ValueChanged<_CoverPresentation>? onPresentation;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tight(Size.square(edge));

  @override
  void paintChildren(FlowPaintingContext context) {
    final frame = presentation();
    final rect = frame.rect;
    onRect?.call(rect);
    onBlend?.call(frame.blend);
    onPresentation?.call(frame);
    final transform = Matrix4.diagonal3Values(
      rect.width / edge,
      rect.height / edge,
      1,
    )..setTranslationRaw(rect.left, rect.top, 0);
    context.paintChild(0, transform: transform);
  }

  @override
  bool shouldRepaint(covariant _CoverFlightDelegate oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.start != start ||
      oldDelegate.destination != destination ||
      oldDelegate.fromBlend != fromBlend ||
      oldDelegate.toBlend != toBlend ||
      oldDelegate.presentation != presentation ||
      oldDelegate.edge != edge;
}

/// Geometry and velocity use the four rectangle edges in physical logical
/// pixels. A fresh destination inherits each component instead of projecting
/// a diagonal flight's momentum onto an unrelated scalar progress value.
class _CoverPresentation {
  const _CoverPresentation(
    this.rect,
    this.velocity,
    this.blend,
    this.blendVelocity,
  );
  final Rect rect, velocity;
  final double blend, blendVelocity;

  _CoverPresentation transformed(Offset Function(Offset) transform) {
    final zero = transform(Offset.zero);
    final first = transform(velocity.topLeft) - zero;
    final last = transform(velocity.bottomRight) - zero;
    return _CoverPresentation(
      Rect.fromPoints(transform(rect.topLeft), transform(rect.bottomRight)),
      Rect.fromLTRB(first.dx, first.dy, last.dx, last.dy),
      blend,
      blendVelocity,
    );
  }
}

class _CoverPhysics extends Simulation {
  _CoverPhysics(_CoverPresentation initial, this.destination, double toBlend)
    : _target = destination() ?? initial.rect,
      _blend = _coverSpring.simulation(
        initial.blend,
        toBlend,
        velocity: initial.blendVelocity,
      ) {
    _edges = _springs(initial, _target);
  }

  final Rect? Function() destination;
  Rect _target;
  double _epoch = 0;
  late List<SpringSimulation> _edges;
  final SpringSimulation _blend;

  static List<SpringSimulation> _springs(_CoverPresentation from, Rect target) {
    final values = [
      from.rect.left,
      from.rect.top,
      from.rect.right,
      from.rect.bottom,
    ];
    final targets = [target.left, target.top, target.right, target.bottom];
    final velocities = [
      from.velocity.left,
      from.velocity.top,
      from.velocity.right,
      from.velocity.bottom,
    ];
    return [
      for (var i = 0; i < 4; i++)
        _coverSpring.simulation(values[i], targets[i], velocity: velocities[i])
          ..tolerance = const Tolerance(distance: .05, velocity: .5),
    ];
  }

  _CoverPresentation _sample(double time) {
    final elapsed = math.max(0.0, time - _epoch);
    return _CoverPresentation(
      Rect.fromLTRB(
        _edges[0].x(elapsed),
        _edges[1].x(elapsed),
        _edges[2].x(elapsed),
        _edges[3].x(elapsed),
      ),
      Rect.fromLTRB(
        _edges[0].dx(elapsed),
        _edges[1].dx(elapsed),
        _edges[2].dx(elapsed),
        _edges[3].dx(elapsed),
      ),
      _blend.x(time).clamp(0.0, 1.0),
      _blend.dx(time),
    );
  }

  _CoverPresentation presentation(double time) {
    final target = destination();
    if (target != null && target != _target) {
      final current = _sample(time);
      _target = target;
      _edges = _springs(current, target);
      _epoch = time;
    }
    return _sample(time);
  }

  @override
  double x(double time) {
    presentation(time);
    return time;
  }

  @override
  double dx(double time) => 1;

  @override
  bool isDone(double time) {
    presentation(time);
    return _blend.isDone(time) &&
        _edges.every((spring) => spring.isDone(math.max(0.0, time - _epoch)));
  }
}

class _CoverBlend extends Animation<double>
    with AnimationWithParentMixin<double> {
  _CoverBlend(this.parent, this._value);
  @override
  final Animation<double> parent;
  final double Function() _value;
  @override
  double get value => _value();
}
