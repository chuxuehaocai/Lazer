import 'build_safe_state.dart';
import 'package:flutter/material.dart';

import '../animation/apple_spring.dart';
import '../data/models.dart';
import 'plate_art.dart';

/// New artwork is opaque underneath the fading composition. Returning to a
/// still-visible track reuses its layer and retargets its spring from the
/// current opacity and velocity, so rapid next/previous keeps the same pixels.
class AnimatedTrackCover extends StatefulWidget {
  const AnimatedTrackCover({
    super.key,
    required this.track,
    required this.direction,
    this.size = 480,
    this.spring = AppleSpring.responsive,
    this.image,
  });

  final Track track;
  final int direction;
  final double size;
  final AppleSpring spring;
  final ImageProvider? image;

  @override
  State<AnimatedTrackCover> createState() => _AnimatedTrackCoverState();
}

class _CoverPlate {
  _CoverPlate(this.track, this.opacity, this.image);
  Track track;
  final AnimationController opacity;
  ImageProvider? image;
}

class _AnimatedTrackCoverState extends State<AnimatedTrackCover>
    with TickerProviderStateMixin, BuildSafeState<AnimatedTrackCover> {
  final List<_CoverPlate> _plates = [];
  late _CoverPlate _current;
  bool _reduced = false;

  _CoverPlate _plate(Track track) {
    final plate = _CoverPlate(
      track,
      AnimationController(vsync: this, value: 1),
      widget.image,
    );
    plate.opacity.addStatusListener((status) {
      if (!mounted) return;
      if (status == AnimationStatus.dismissed && plate != _current) {
        setState(() => _plates.remove(plate));
        plate.opacity.dispose();
      } else if (status == AnimationStatus.completed && plate == _current) {
        // Everything below an opaque target is invisible. Release those
        // images immediately instead of keeping hidden live cache listeners.
        final index = _plates.indexOf(plate);
        if (index > 0) {
          final hidden = _plates.take(index).toList();
          setState(() => _plates.removeRange(0, index));
          for (final entry in hidden) {
            entry.opacity.dispose();
          }
        }
      }
    });
    return plate;
  }

  @override
  void initState() {
    super.initState();
    _current = _plate(widget.track);
    _plates.add(_current);
  }

  void _snap() {
    final stale = _plates.where((plate) => plate != _current).toList();
    _plates
      ..clear()
      ..add(_current);
    _current.opacity.stop();
    if (_current.opacity.value != 1) {
      // Setting a controller value during inherited dependency rebuild can
      // dirty FadeTransition while its ancestor is building. Defer only this
      // reduced-motion assignment; the frame itself already renders current.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _plates.contains(_current)) _current.opacity.value = 1;
      });
    }
    for (final plate in stale) {
      plate.opacity.dispose();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced && _plates.length > 1) _snap();
  }

  @override
  void didUpdateWidget(covariant AnimatedTrackCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id == widget.track.id) {
      _current.track = widget.track;
      _current.image = widget.image;
      return;
    }
    _CoverPlate? matching;
    for (final plate in _plates) {
      if (plate.track.id == widget.track.id) matching = plate;
    }
    _current = matching ?? _plate(widget.track);
    _current.track = widget.track;
    _current.image = widget.image;
    if (matching == null) _plates.insert(0, _current);
    if (_reduced) {
      _snap();
      return;
    }
    final index = _plates.indexOf(_current);
    for (final plate in _plates.skip(index + 1).toList()) {
      plate.opacity.springTo(0, spring: widget.spring);
    }
    _current.opacity.springTo(1, spring: widget.spring);
  }

  @override
  void dispose() {
    for (final plate in _plates) {
      plate.opacity.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        for (final plate in (_reduced ? <_CoverPlate>[_current] : _plates))
          ExcludeSemantics(
            key: ObjectKey(plate),
            excluding: plate != _current,
            child: IgnorePointer(
              ignoring: plate != _current,
              child: FadeTransition(
                opacity: _reduced
                    ? const AlwaysStoppedAnimation(1.0)
                    : plate.opacity,
                child: RepaintBoundary(
                  child: PlateArt(
                    key: ValueKey<String>(plate.track.id),
                    seed: plate.track.coverSeed,
                    coverUrl: plate.track.coverUrl,
                    image: plate.image,
                    radius: BorderRadius.zero,
                    size: widget.size,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
