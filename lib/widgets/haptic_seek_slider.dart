import 'build_safe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';
import '../theme/shape_scale.dart';

class HapticSeekSlider extends StatefulWidget {
  const HapticSeekSlider({super.key, required this.state});
  final AppState state;
  @override
  State<HapticSeekSlider> createState() => _HapticSeekSliderState();
}

class _HapticSeekSliderState extends State<HapticSeekSlider>
    with WidgetsBindingObserver, BuildSafeState<HapticSeekSlider> {
  /// A D-pad step on the seek rail, in fractional track length.
  static const double _step = .02;

  bool _focused = false;
  bool _dragging = false;
  Object? _dragSource;

  Object get _source =>
      (widget.state, widget.state.current?.id, widget.state.queueIndex);
  bool get _seekable =>
      widget.state.current != null &&
      widget.state.current!.duration > Duration.zero &&
      widget.state.seekLimitFraction > 0;
  double? _preview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancel();
  }

  void _cancel() {
    if (!_dragging && _preview == null) return;
    setState(() {
      _dragging = false;
      _dragSource = null;
      _preview = null;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _start(double value) {
    _dragging = true;
    _dragSource = _source;
    setState(() => _preview = value);
  }

  void _change(double value) {
    if (!_dragging) {
      widget.state.seek(value.clamp(0, widget.state.seekLimitFraction));
    } else if (_dragSource == _source) {
      setState(() => _preview = value.clamp(0, widget.state.seekLimitFraction));
    }
  }

  void _end(double value) {
    if (_dragging && _dragSource == _source) {
      widget.state.seek(value.clamp(0, widget.state.seekLimitFraction));
    }
    setState(() {
      _dragging = false;
      _preview = null;
    });
  }

  void _nudge(double delta) {
    final AppState state = widget.state;
    if (!_seekable) return;
    state.seek(
      (state.progress + delta).clamp(0.0, state.seekLimitFraction).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_dragging && _dragSource != _source) {
      _dragging = false;
      _dragSource = null;
      _preview = null;
    }
    final Widget slider = AccessibleSlider(
      key: ValueKey(_source),
      maxInteractiveValue: widget.state.seekLimitFraction,
      semanticLabel: '播放进度',
      value: _dragging && _dragSource == _source
          ? (_preview ?? widget.state.progress)
          : widget.state.progress,
      secondaryTrackValue: widget.state.seekLimitFraction,
      detentFeedback: true,
      onChanged: _seekable ? _change : null,
      onChangeStart: _start,
      onChangeEnd: _end,
      onChangeCancel: _cancel,
    );
    // Material sliders spend the up/down keys on their value. Those keys must
    // always leave the rail instead: a remote's d-pad moves to the row above
    // or below, not scrubs the song. The wrapper is unconditional so a build
    // where TvScope has not been installed (or a desktop window with a
    // keyboard) cannot fall back to the bare slider. Left/right still nudge.
    return FocusableActionDetector(
      enabled: _seekable,
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
          // The wrapper is a focus stop on every platform that has a keyboard
          // (see the note above), so the ring follows focus rather than TvScope:
          // gating it on `tv` left a desktop user tabbing onto the rail and
          // nudging the playhead with the arrow keys with nothing to show where
          // focus was.
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: TvFocusOutline(borderRadius: BorderRadius.circular(8 * AppleShape.scaleOf(context))),
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
