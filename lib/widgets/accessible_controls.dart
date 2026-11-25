import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../interaction/app_haptics.dart';
import '../l10n/app_localizations.dart';
import '../tv/tv_mode.dart';
import 'interaction_feedback.dart';

/// Keep a control and its semantics in the same island.
///
/// Material sliders use an OverlayPortal for their value indicator. When the
/// control animates out, a page-level overlay can serialize its semantics
/// separately from the disappearing anchor and leave orphan AX nodes. A local
/// overlay keeps both updates in the same subtree. Size it to the control so
/// it cannot cover adjacent hit targets; Overlay does not add a FocusScope, so
/// remote traversal can still enter and leave the control.
class SemanticsPortal extends StatelessWidget {
  const SemanticsPortal({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(
    // 不建独立语义容器：容器节点在页面重建/隐藏时最容易变成孤立 AX 节点，
    // 引擎就会刷 "will not be in the tree"。标签合并到最近的可聚焦节点即可。
    container: false,
    child: Overlay.wrap(
      alwaysSizeToContent: true,
      clipBehavior: Clip.none,
      child: child,
    ),
  );
}

/// A semantics-labelled Material slider. [detentFeedback] opts into the app's
/// haptics: a grab clicks once, each notch crossed clicks again (stronger at
/// the ends), mirroring the seek bar so dragged values feel like a dial.
class AccessibleSlider extends StatefulWidget {
  const AccessibleSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.secondaryTrackValue,
    this.divisions,
    this.label,
    this.onChangeStart,
    this.onChangeEnd,
    this.onChangeCancel,
    this.maxInteractiveValue,
    this.semanticLabel,
    this.semanticFormatterCallback,
    this.focusNode,
    this.autofocus = false,
    this.detentFeedback = false,
  });
  final double value;
  final double min;
  final double max;
  final double? secondaryTrackValue;
  final int? divisions;
  final String? label;
  final String? semanticLabel;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final VoidCallback? onChangeCancel;

  /// Limits seeking without changing the full rail or its buffered indicator.
  final double? maxInteractiveValue;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool detentFeedback;
  @override
  State<AccessibleSlider> createState() => _AccessibleSliderState();
}

class _AccessibleSliderState extends State<AccessibleSlider>
    with WidgetsBindingObserver {
  SliderDetents? _detents;
  int? _pointer;
  bool _pointerInteraction = false;
  bool _sliderDragging = false;
  bool _cancelled = false;
  int _interaction = 0;
  late double _displayValue = _clamp(widget.value);

  double _clamp(double value) => value
      .clamp(
        widget.min,
        (widget.maxInteractiveValue ?? widget.max).clamp(
          widget.min,
          widget.max,
        ),
      )
      .toDouble();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant AccessibleSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onChanged == null ||
        widget.min != oldWidget.min ||
        widget.max != oldWidget.max) {
      _cancelInteraction(rebuild: false);
    }
    if (!_sliderDragging && _pointer == null) {
      _displayValue = _clamp(widget.value);
    }
    _displayValue = _clamp(_displayValue);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancelInteraction();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detents?.end();
    super.dispose();
  }

  void _cancelInteraction({bool rebuild = true}) {
    final bool active = _pointerInteraction || _sliderDragging;
    _cancelled = true;
    _interaction++;
    _pointer = null;
    _pointerInteraction = false;
    _sliderDragging = false;
    _detents?.end();
    _detents = null;
    _displayValue = _clamp(widget.value);
    if (active) widget.onChangeCancel?.call();
    if (rebuild && active && mounted) setState(() {});
  }

  void _handleChangeStart(double value, FeedbackCallback? feedback) {
    if (widget.onChanged == null || (_cancelled && _pointerInteraction)) return;
    if (!_pointerInteraction) {
      _cancelled = false;
      _interaction++;
    }
    _sliderDragging = true;
    _displayValue = _clamp(value);
    if (widget.detentFeedback) {
      _detents = SliderDetents(
        min: widget.min,
        max: widget.max,
        steps: widget.divisions,
      )..begin(value);
      if (feedback != null) unawaited(feedback(detent: true));
    }
    widget.onChangeStart?.call(_displayValue);
  }

  void _handleChangeEnd(double value) {
    final int interaction = _interaction;
    void finish() {
      if (!mounted ||
          _cancelled ||
          interaction != _interaction ||
          widget.onChanged == null) {
        return;
      }
      _sliderDragging = false;
      _pointerInteraction = false;
      _pointer = null;
      _detents?.end();
      _detents = null;
      widget.onChangeEnd?.call(_clamp(value));
      setState(() => _displayValue = _clamp(widget.value));
    }

    // Material also ends its gesture on PointerCancel. Wait until that event
    // has reached our Listener before deciding whether a pointer edit commits.
    if (_pointerInteraction) {
      scheduleMicrotask(finish);
    } else {
      finish();
    }
  }

  void _handleChanged(double value, FeedbackCallback? feedback) {
    if (!mounted || widget.onChanged == null || _cancelled) return;
    final double next = _clamp(value);
    setState(() => _displayValue = next);
    if (_detents != null && feedback != null && _detents!.update(next)) {
      unawaited(
        feedback(
          detent: true,
          boundary:
              next <= widget.min ||
              next >= (widget.maxInteractiveValue ?? widget.max),
        ),
      );
    }
    widget.onChanged!(next);
  }

  @override
  Widget build(BuildContext context) {
    final FeedbackCallback? feedback = widget.detentFeedback
        ? InteractionFeedback.of(context)
        : null;
    return SemanticsPortal(
      child: MergeSemantics(
        child: Semantics(
          label: widget.semanticLabel == null
              ? null
              : context.tr(widget.semanticLabel!),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (widget.onChanged != null &&
                  event.buttons == kPrimaryButton &&
                  _pointer == null) {
                _pointer = event.pointer;
                _pointerInteraction = true;
                _cancelled = false;
                _interaction++;
              }
            },
            onPointerUp: (event) {
              if (_pointer == event.pointer) _pointer = null;
            },
            onPointerCancel: (event) {
              if (_pointer == event.pointer) _cancelInteraction();
            },
            // Material owns pointer geometry, RTL, buttons and gesture-arena
            // cancellation. A second raw move handler would duplicate changes.
            child: Slider(
              value: _clamp(_displayValue),
              min: widget.min,
              max: widget.max,
              secondaryTrackValue: widget.secondaryTrackValue?.clamp(
                widget.min,
                widget.max,
              ),
              divisions: widget.divisions,
              label: widget.label == null ? null : context.tr(widget.label!),
              onChangeStart: (value) => _handleChangeStart(value, feedback),
              onChanged: widget.onChanged == null
                  ? null
                  : (value) => _handleChanged(value, feedback),
              onChangeEnd: _handleChangeEnd,
              semanticFormatterCallback:
                  widget.semanticFormatterCallback == null
                  ? null
                  : (value) =>
                        context.tr(widget.semanticFormatterCallback!(value)),
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
            ),
          ),
        ),
      ),
    );
  }
}

/// Give each portal anchor a separate node while retaining the page overlay's
/// full bounds for tooltip placement and long labels.
class AccessibleTooltip extends StatelessWidget {
  const AccessibleTooltip({
    super.key,
    required this.message,
    required this.child,
  });
  final String message;
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Tooltip(
      message: context.tr(message),
      enableFeedback: false,
      child: child,
    ),
  );
}

class AccessibleIconButton extends IconButton {
  const AccessibleIconButton({
    super.key,
    required super.icon,
    required super.onPressed,
    super.tooltip,
    super.isSelected,
    super.iconSize,
    super.padding,
    super.style,
    super.color,
    super.constraints,
    super.visualDensity,
    super.alignment,
    super.focusNode,
    super.autofocus,
    super.enableFeedback,
    this.semanticLabel,
  });

  /// Label for screen readers when this button cannot carry a [tooltip].
  ///
  /// A Tooltip hosts its bubble through an OverlayPortal that computes a paint
  /// transform during layout. Inside another overlay portal's deferred subtree
  /// — the floating window capsule paints its buttons that way — that nesting
  /// trips the overlay theater's depth assertion, so those buttons keep the
  /// label here instead.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // 同上：容器节点会在按钮重建时产生孤立 AX 节点。
      container: false,
      label: semanticLabel == null ? null : context.tr(semanticLabel!),
      child: TvFocusHighlight(
        child: SpringPress(
          builder: (context, states) => IconButton(
            statesController: states,
            icon: icon,
            onPressed: feedbackAction(context, onPressed),
            tooltip: tooltip == null ? null : context.tr(tooltip!),
            isSelected: isSelected,
            iconSize: iconSize,
            padding: padding,
            style: style,
            color: color,
            constraints: constraints,
            visualDensity: visualDensity,
            alignment: alignment,
            focusNode: focusNode,
            autofocus: autofocus,
            enableFeedback: false,
          ),
        ),
      ),
    );
  }
}
