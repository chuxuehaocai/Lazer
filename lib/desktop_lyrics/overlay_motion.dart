import '../lyrics/spring.dart';

/// Holds only the visible lyric rows and one entering neighbour at either edge.
/// A seek never retains springs for rows that the overlay no longer paints.
class OverlayMotionBuffer {
  final Map<int, OverlayLineMotion> _rows = {};
  Iterable<OverlayLineMotion> get values => _rows.values;
  int get length => _rows.length;
  OverlayLineMotion? operator [](int index) => _rows[index];
  void clear() => _rows.clear();

  void retarget({
    required int focus,
    required int lineCount,
    required int documentLength,
    required double slot,
    required double padding,
    required double inactiveScale,
    required LyricSpringParams params,
    required bool seeking,
    required bool instant,
  }) {
    final count = lineCount.clamp(1, 5);
    final leading = count ~/ 2;
    final indices = <int>[
      for (var offset = -leading - 1; offset <= count - leading; offset++)
        if (focus + offset >= 0 && focus + offset < documentLength)
          focus + offset,
    ];
    final keep = indices.toSet();
    _rows.removeWhere((index, _) => !keep.contains(index));
    if (indices.isEmpty) return;
    final activeIndex = indices.indexOf(focus);
    final delays = lyricStaggerDelays(
      [
        for (var i = 0; i < indices.length; i++)
          i < activeIndex ? -slot * 2 : (i - activeIndex) * slot,
      ],
      [for (final _ in indices) slot],
      activeIndex,
      disabled: seeking,
    );
    for (var i = 0; i < indices.length; i++) {
      final index = indices[i];
      final target = padding + (index - focus + leading) * slot;
      final scale = index == focus ? 100.0 : inactiveScale;
      final motion = _rows.putIfAbsent(
        index,
        () => OverlayLineMotion(
          target + (i >= activeIndex ? slot : -slot),
          scale: scale,
        ),
      );
      if (instant) {
        motion.y.setPosition(target);
        motion.scale.setPosition(scale);
      } else {
        motion.y.setParameters(params);
        motion.y.setTarget(target, delay: delays[i]);
        motion.scale.setTarget(scale);
      }
    }
  }
}

class OverlayLineMotion {
  OverlayLineMotion(double position, {required double scale})
    : y = LyricSpring(position),
      scale = LyricSpring(
        scale,
        params: const LyricSpringParams(mass: 2, damping: 25, stiffness: 100),
      );

  final LyricSpring y;
  final LyricSpring scale;
  bool get arrived => y.arrived && scale.arrived;
}
