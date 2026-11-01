import 'package:flutter/material.dart';

class _CoverOrigin {
  const _CoverOrigin(this.identity, this.rect, this.recordedAt);
  final String identity;
  final Rect rect;
  final DateTime recordedAt;
}

_CoverOrigin? _pendingCover;

/// Records the exact artwork bounds before the content pane changes. Unlike a
/// route Hero, this also works with the shell's in-place page transitions.
void rememberCoverTransition(String identity, GlobalKey coverKey) {
  final box = coverKey.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
  _pendingCover = _CoverOrigin(
    identity,
    box.localToGlobal(Offset.zero) & box.size,
    DateTime.now(),
  );
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

class _CoverTransitionTargetState extends State<CoverTransitionTarget>
    with SingleTickerProviderStateMixin {
  final GlobalKey _destination = GlobalKey();
  late final AnimationController _controller;
  OverlayEntry? _flight;
  bool _flying = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
    _beginPendingFlight();
  }

  @override
  void didUpdateWidget(covariant CoverTransitionTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _controller.stop();
      _removeFlight();
      _flying = false;
      _beginPendingFlight();
    }
  }

  void _beginPendingFlight() {
    final generation = ++_generation;
    final origin = _pendingCover;
    if (origin == null || origin.identity != widget.identity) return;
    _pendingCover = null;
    if (DateTime.now().difference(origin.recordedAt).inMilliseconds > 1200) {
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
        return;
      }
      final start = Rect.fromPoints(
        overlayBox.globalToLocal(origin.rect.topLeft),
        overlayBox.globalToLocal(origin.rect.bottomRight),
      );
      _flight = OverlayEntry(
        builder: (context) => AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final target = _destination.currentContext?.findRenderObject();
            if (target is! RenderBox || !target.hasSize) {
              return const SizedBox.shrink();
            }
            final end = Rect.fromPoints(
              overlayBox.globalToLocal(target.localToGlobal(Offset.zero)),
              overlayBox.globalToLocal(
                target.localToGlobal(target.size.bottomRight(Offset.zero)),
              ),
            );
            final progress = Curves.easeInOutCubic.transform(_controller.value);
            final rect = Rect.lerp(start, end, progress)!;
            return Positioned.fromRect(
              key: const ValueKey<String>('cover-transition-flight'),
              rect: rect,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: InheritedTheme.captureAll(
                    this.context,
                    ClipRRect(
                      borderRadius: BorderRadius.circular(widget.radius),
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox.square(
                          dimension: widget.size,
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      overlay.insert(_flight!);
      _controller.forward(from: 0).whenComplete(() {
        if (!mounted || generation != _generation) return;
        _removeFlight();
        setState(() => _flying = false);
      });
    });
  }

  void _removeFlight() {
    _flight?.remove();
    _flight?.dispose();
    _flight = null;
  }

  @override
  void dispose() {
    _removeFlight();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: _destination,
    dimension: widget.size,
    child: Opacity(opacity: _flying ? 0 : 1, child: widget.child),
  );
}
