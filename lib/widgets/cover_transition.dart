import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../animation/view_transitions.dart';

class _CoverOrigin {
  const _CoverOrigin(this.identity, this.rect, this.sourceKey, this.recordedAt);
  final String identity;
  final Rect rect;
  final GlobalKey sourceKey;
  final DateTime recordedAt;
}

_CoverOrigin? _pendingCover;
final Map<String, _CoverTransitionTargetState> _targets =
    <String, _CoverTransitionTargetState>{};
final Map<String, Set<GlobalKey>> _sourceKeys = <String, Set<GlobalKey>>{};
final ValueNotifier<Set<GlobalKey>> _hiddenSources =
    ValueNotifier<Set<GlobalKey>>(<GlobalKey>{});
OverlayEntry? _returnFlight;
GlobalKey? _returnSource;
int _returnGeneration = 0;

void _hideSource(GlobalKey key, bool hidden) {
  void update() {
    final next = Set<GlobalKey>.of(_hiddenSources.value);
    if (hidden ? next.add(key) : next.remove(key)) _hiddenSources.value = next;
  }

  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    WidgetsBinding.instance.addPostFrameCallback((_) => update());
  } else {
    update();
  }
}

/// A source keeps its layout while its artwork travels in the root overlay.
class CoverTransitionSource extends StatefulWidget {
  const CoverTransitionSource({
    required GlobalKey super.key,
    required this.child,
    this.identity,
  });
  final Widget child;
  final String? identity;

  @override
  State<CoverTransitionSource> createState() => _CoverTransitionSourceState();
}

class _CoverTransitionSourceState extends State<CoverTransitionSource> {
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
  void dispose() {
    _unregister(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Set<GlobalKey>>(
    valueListenable: _hiddenSources,
    child: RepaintBoundary(child: widget.child),
    builder: (context, hidden, child) =>
        Opacity(opacity: hidden.contains(widget.key) ? 0 : 1, child: child),
  );
}

GlobalKey? _liveSourceKey(_CoverOrigin origin) {
  if (origin.sourceKey.currentContext != null) return origin.sourceKey;
  // A responsive rebuild can replace a shelf's local key. Measure its newly
  // mounted card instead of replaying the old screen position or DPI.
  GlobalKey? best;
  var distance = double.infinity;
  for (final key in _sourceKeys[origin.identity] ?? <GlobalKey>{}) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    final delta = (center - origin.rect.center).distanceSquared;
    if (delta < distance) {
      distance = delta;
      best = key;
    }
  }
  return best;
}

void _removeReturnFlight() {
  _returnGeneration++;
  _returnFlight?.remove();
  _returnFlight?.dispose();
  _returnFlight = null;
  final source = _returnSource;
  _returnSource = null;
  if (source != null) _hideSource(source, false);
}

/// Cancels visual work when the shell changes account, section, or closes.
void cancelCoverTransitions() {
  _pendingCover = null;
  _removeReturnFlight();
  for (final target in _targets.values.toList()) {
    target._cancelFlight();
  }
  for (final key in _hiddenSources.value.toList()) {
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
  cancelCoverTransitions();
  _pendingCover = _CoverOrigin(
    identity,
    Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    ),
    coverKey,
    DateTime.now(),
  );
  if (!(MediaQuery.maybeOf(coverKey.currentContext!)?.disableAnimations ??
      false)) {
    _hideSource(coverKey, true);
  }
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
      _origin = null;
      _removeFlight();
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
    _origin = origin;
    if (DateTime.now().difference(origin.recordedAt).inMilliseconds > 1200) {
      _hideSource(origin.sourceKey, false);
      return;
    }
    _flying = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_flying || generation != _generation) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      final overlayBox = overlay?.context.findRenderObject();
      if (overlay == null ||
          overlayBox is! RenderBox ||
          MediaQuery.disableAnimationsOf(context)) {
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
            destination: destinationRect,
            edge: widget.size,
            onRect: (rect) => _flightRect = rect,
            onComplete: () {
              if (!mounted || generation != _generation) return;
              _removeFlight();
              _flightRect = null;
              _hideSource(origin.sourceKey, false);
              setState(() => _flying = false);
            },
            child: artwork,
          ),
        ),
      );
      overlay.insert(_flight!);
    });
  }

  void _removeFlight() {
    _flight?.remove();
    _flight?.dispose();
    _flight = null;
  }

  void _cancelFlight() {
    _generation++;
    _removeFlight();
    _flightRect = null;
    if (_origin != null) _hideSource(_origin!.sourceKey, false);
    if (mounted && _flying) setState(() => _flying = false);
  }

  bool _returnToSource() {
    final origin = _origin;
    final sourceKey = origin == null ? null : _liveSourceKey(origin);
    final source = sourceKey?.currentContext?.findRenderObject();
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
          overlayBox.globalToLocal(target.localToGlobal(Offset.zero)),
          overlayBox.globalToLocal(
            target.localToGlobal(target.size.bottomRight(Offset.zero)),
          ),
        );
    _generation++;
    _removeFlight();
    _flightRect = null;
    _removeReturnFlight();
    _hideSource(sourceKey, true);
    _returnSource = sourceKey;
    _returning = true;
    setState(() => _flying = true);
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
      if (currentSource.currentContext == null) {
        final replacement = _liveSourceKey(origin);
        if (replacement != null && replacement != currentSource) {
          _hideSource(currentSource, false);
          currentSource = replacement;
          _hideSource(currentSource, true);
          _returnSource = currentSource;
        }
      }
      final box = currentSource.currentContext?.findRenderObject();
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

    // Insertion follows the returning page's first layout, so neither old
    // scroll offsets nor a previous DPI can become the animation destination.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _returnGeneration || !overlay.mounted) return;
      if (destination() == null) {
        _removeReturnFlight();
        if (mounted) setState(() => _flying = false);
        return;
      }
      _returnFlight = OverlayEntry(
        builder: (_) => Positioned.fill(
          child: _CoverFlight(
            start: start,
            destination: destination,
            edge: edge,
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
    });
    return true;
  }

  @override
  void dispose() {
    _generation++;
    _removeFlight();
    if (!_returning && _origin != null) _hideSource(_origin!.sourceKey, false);
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
class _CoverFlight extends StatefulWidget {
  const _CoverFlight({
    required this.start,
    required this.destination,
    required this.edge,
    required this.onComplete,
    required this.child,
    this.onRect,
  });

  final Rect start;
  final Rect? Function() destination;
  final double edge;
  final VoidCallback onComplete;
  final Widget child;
  final ValueChanged<Rect>? onRect;

  @override
  State<_CoverFlight> createState() => _CoverFlightState();
}

class _CoverFlightState extends State<_CoverFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 420),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onComplete();
      });

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
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
        ),
        children: [widget.child],
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
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Rect start;
  final Rect? Function() destination;
  final double edge;
  final ValueChanged<Rect>? onRect;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tight(Size.square(edge));

  @override
  void paintChildren(FlowPaintingContext context) {
    final progress = ViewMotion.curve.transform(animation.value);
    final rect = Rect.lerp(start, destination() ?? start, progress)!;
    onRect?.call(rect);
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
      oldDelegate.edge != edge;
}
