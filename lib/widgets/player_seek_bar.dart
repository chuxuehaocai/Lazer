import 'package:flutter/material.dart';
import '../state/app_state.dart';
import 'haptic_seek_slider.dart';

/// Apple Music style rail: a plain white bar over the artwork wash.
///
/// The rail stays thin at rest and swells on press, so the drag target is
/// comfortable without turning the rail into a heavy element on screen.
class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.state,
    this.trackHeight = 4,
    this.thumbRadius = 7,
  });

  final AppState state;
  final double trackHeight, thumbRadius;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar>
    with WidgetsBindingObserver {
  bool _grabbing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _setGrabbing(false);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setGrabbing(bool value) {
    if (_grabbing == value) return;
    setState(() => _grabbing = value);
  }

  @override
  Widget build(BuildContext context) {
    final double railHeight = _grabbing
        ? widget.trackHeight + 3
        : widget.trackHeight;
    final double thumbRadius = _grabbing
        ? widget.thumbRadius + 3
        : widget.thumbRadius;
    // Leaf: the only part of Now Playing that consumes 100 ms ticks.
    return Listener(
      onPointerDown: (_) => _setGrabbing(true),
      onPointerUp: (_) => _setGrabbing(false),
      onPointerCancel: (_) => _setGrabbing(false),
      child: AnimatedBuilder(
        animation: widget.state.all,
        builder: (BuildContext context, _) => SliderTheme(
          data: SliderThemeData(
            trackHeight: railHeight,
            activeTrackColor: Colors.white,
            secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.68),
            inactiveTrackColor: Colors.white.withValues(alpha: 0.32),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withValues(alpha: 0.18),
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: HapticSeekSlider(state: widget.state),
        ),
      ),
    );
  }
}
