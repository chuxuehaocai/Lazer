import 'build_safe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
    with WidgetsBindingObserver, BuildSafeState<PlayerSeekBar> {
  bool _grabbing = false;
  Object? _grabSource;

  Object get _source =>
      (widget.state, widget.state.current?.id, widget.state.queueIndex);
  bool get _seekable =>
      widget.state.current != null &&
      widget.state.current!.duration > Duration.zero &&
      widget.state.seekLimitFraction > 0;

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
    // Leaf: the only part of Now Playing that consumes 100 ms ticks.
    return Listener(
      onPointerDown: (event) {
        if (_seekable && event.buttons == kPrimaryButton) {
          _grabSource = _source;
          _setGrabbing(true);
        }
      },
      onPointerUp: (_) => _setGrabbing(false),
      onPointerCancel: (_) => _setGrabbing(false),
      child: AnimatedBuilder(
        // TickerMode only mutes animation controllers, not position updates.
        animation: TickerMode.valuesOf(context).enabled
            ? widget.state.all
            : widget.state,
        builder: (BuildContext context, _) => SliderTheme(
          data: SliderThemeData(
            trackHeight: _grabbing && _grabSource == _source && _seekable
                ? widget.trackHeight + 3
                : widget.trackHeight,
            activeTrackColor: Colors.white,
            secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.68),
            inactiveTrackColor: Colors.white.withValues(alpha: 0.32),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withValues(alpha: 0.18),
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius:
                  _grabbing && _grabSource == _source && _seekable
                  ? widget.thumbRadius + 3
                  : widget.thumbRadius,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: HapticSeekSlider(state: widget.state),
        ),
      ),
    );
  }
}
