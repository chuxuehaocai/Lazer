import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';

class HapticSeekSlider extends StatefulWidget {
  const HapticSeekSlider({super.key, required this.state});
  final AppState state;
  @override
  State<HapticSeekSlider> createState() => _HapticSeekSliderState();
}

class _HapticSeekSliderState extends State<HapticSeekSlider> {
  /// A D-pad step on the seek rail, in fractional track length.
  static const double _step = .02;

  bool _focused = false;
  bool _dragging = false;
  String? _dragTrackId;
  double? _preview;

  void _start(double value) {
    _dragging = true;
    _dragTrackId = widget.state.current?.id;
    setState(() => _preview = value);
  }

  void _change(double value) {
    if (!_dragging) {
      widget.state.seek(value);
    } else if (_dragTrackId == widget.state.current?.id) {
      setState(() => _preview = value.clamp(0, widget.state.seekLimitFraction));
    }
  }

  void _end(double value) {
    if (_dragging && _dragTrackId == widget.state.current?.id) {
      widget.state.seek(value);
    }
    setState(() {
      _dragging = false;
      _preview = null;
    });
  }

  void _nudge(double delta) {
    final AppState state = widget.state;
    if (state.current == null) return;
    state.seek(
      (state.progress + delta).clamp(0.0, state.seekLimitFraction).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget slider = AccessibleSlider(
      semanticLabel: '播放进度',
      value: _dragging && _dragTrackId == widget.state.current?.id
          ? (_preview ?? widget.state.progress)
          : widget.state.progress,
      secondaryTrackValue: widget.state.seekLimitFraction,
      detentFeedback: true,
      onChanged: widget.state.current == null ? null : _change,
      onChangeStart: _start,
      onChangeEnd: _end,
    );
    final bool tv = TvScope.isActive(context);
    // Material sliders spend the up/down keys on their value. Those keys must
    // always leave the rail instead: a remote's d-pad moves to the row above
    // or below, not scrubs the song. The wrapper is unconditional so a build
    // where TvScope has not been installed (or a desktop window with a
    // keyboard) cannot fall back to the bare slider. Left/right still nudge.
    return FocusableActionDetector(
      enabled: widget.state.current != null,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekStepIntent(-_step),
        SingleActivator(LogicalKeyboardKey.arrowRight): _SeekStepIntent(_step),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
          TraversalDirection.up,
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
          TraversalDirection.down,
        ),
      },
      actions: <Type, Action<Intent>>{
        _SeekStepIntent: CallbackAction<_SeekStepIntent>(
          onInvoke: (_SeekStepIntent intent) {
            _nudge(intent.delta);
            return null;
          },
        ),
      },
      onFocusChange: (bool value) => setState(() => _focused = value),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ExcludeFocus(child: slider),
          if (tv && _focused)
            Positioned.fill(
              child: IgnorePointer(
                child: TvFocusOutline(borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    );
  }
}

class _SeekStepIntent extends Intent {
  const _SeekStepIntent(this.delta);
  final double delta;
}
