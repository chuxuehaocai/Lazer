import 'package:flutter/material.dart';

/// A cold detail cover stays on its placeholder until its first image frame,
/// then dissolves over that opaque base. Warm images and reduced motion show
/// their frame immediately. Browse thumbnails opt out of this animation.
class ArtworkReveal extends StatefulWidget {
  const ArtworkReveal({
    super.key,
    required this.ready,
    required this.synchronous,
    required this.placeholder,
    required this.child,
  });

  final bool ready;
  final bool synchronous;
  final Widget placeholder;
  final Widget child;

  @override
  State<ArtworkReveal> createState() => _ArtworkRevealState();
}

class _ArtworkRevealState extends State<ArtworkReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  bool _reduceMotion = false;

  void _updateReveal() {
    if (!widget.ready) {
      _opacity.value = 0;
    } else if (widget.synchronous || _reduceMotion) {
      _opacity.value = 1;
    } else {
      _opacity.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _updateReveal();
  }

  @override
  void didUpdateWidget(ArtworkReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready != oldWidget.ready ||
        widget.synchronous != oldWidget.synchronous) {
      _updateReveal();
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.synchronous || _reduceMotion) {
      return widget.ready ? widget.child : widget.placeholder;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(child: widget.placeholder),
        FadeTransition(
          opacity: _opacity,
          child: RepaintBoundary(child: widget.child),
        ),
      ],
    );
  }
}
