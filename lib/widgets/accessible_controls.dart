import 'dart:async';

import 'package:flutter/material.dart';
import '../interaction/app_haptics.dart';
import '../l10n/app_localizations.dart';
import 'interaction_feedback.dart';

/// Keep a control and its semantics in the same island.
///
/// Putting every slider and dropdown inside a nested [Overlay] can make the
/// overlay's render layer win hit testing on touch surfaces: sliders remain
/// visible but cannot be dragged. A semantics container is sufficient here;
/// controls keep their own native popup and gesture handling.
class SemanticsPortal extends StatelessWidget {
  const SemanticsPortal({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Semantics(container: true, child: child);
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
  final SemanticFormatterCallback? semanticFormatterCallback;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool detentFeedback;
  @override
  State<AccessibleSlider> createState() => _AccessibleSliderState();
}

class _AccessibleSliderState extends State<AccessibleSlider> {
  SliderDetents? _detents;
  final Set<int> _dragPointers = <int>{};
  bool _sliderDragging = false;
  late double _displayValue = widget.value;

  @override
  void didUpdateWidget(covariant AccessibleSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // During a drag the parent may rebuild with the value from the previous
    // frame (for example while a setting is being persisted). Do not replace
    // the thumb's local value with that stale value until the gesture ends.
    if (widget.value != oldWidget.value &&
        !_sliderDragging &&
        _dragPointers.isEmpty) {
      _displayValue = widget.value;
    }
  }

  void _handleChangeStart(double value, FeedbackCallback? feedback) {
    _sliderDragging = true;
    _displayValue = value.clamp(widget.min, widget.max);
    if (widget.detentFeedback) {
      _detents = SliderDetents(
        min: widget.min,
        max: widget.max,
        steps: widget.divisions,
      )..begin(value);
      if (feedback != null) unawaited(feedback(detent: true));
    }
    widget.onChangeStart?.call(value);
  }

  void _handleChangeEnd(double value) {
    _detents?.end();
    _detents = null;
    widget.onChangeEnd?.call(value);
    _sliderDragging = false;
    if (mounted) setState(() {});
  }

  void _handleChanged(double value, FeedbackCallback? feedback) {
    if (!mounted || widget.onChanged == null) return;
    final double next = value.clamp(widget.min, widget.max);
    setState(() => _displayValue = next);
    if (_detents != null && feedback != null && _detents!.update(next)) {
      unawaited(
        feedback(
          detent: true,
          boundary: next <= widget.min || next >= widget.max,
        ),
      );
    }
    widget.onChanged!(next);
  }

  void _updateFromPointer(
    PointerMoveEvent event,
    double width,
    FeedbackCallback? feedback,
  ) {
    if (!_dragPointers.contains(event.pointer) || widget.onChanged == null) {
      return;
    }
    if (width <= 0) return;
    double fraction = (event.localPosition.dx / width).clamp(0.0, 1.0);
    final int? divisions = widget.divisions;
    if (divisions != null && divisions > 0) {
      fraction = (fraction * divisions).round() / divisions;
    }
    _handleChanged(widget.min + (widget.max - widget.min) * fraction, feedback);
  }

  @override
  Widget build(BuildContext context) {
    final FeedbackCallback? feedback = widget.detentFeedback
        ? InteractionFeedback.of(context)
        : null;
    final ValueChanged<double>? onChanged = widget.onChanged;
    return SemanticsPortal(
      child: MergeSemantics(
        child: Semantics(
          label: widget.semanticLabel == null
              ? null
              : context.tr(widget.semanticLabel!),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (PointerDownEvent event) {
                    if (widget.onChanged != null) {
                      _dragPointers.add(event.pointer);
                      _sliderDragging = true;
                    }
                  },
                  onPointerMove: (PointerMoveEvent event) =>
                      _updateFromPointer(event, constraints.maxWidth, feedback),
                  onPointerUp: (PointerUpEvent event) {
                    _dragPointers.remove(event.pointer);
                    if (_dragPointers.isEmpty) _sliderDragging = false;
                  },
                  onPointerCancel: (PointerCancelEvent event) {
                    _dragPointers.remove(event.pointer);
                    if (_dragPointers.isEmpty) _sliderDragging = false;
                  },
                  child: Slider(
                    value: _displayValue.clamp(widget.min, widget.max),
                    min: widget.min,
                    max: widget.max,
                    secondaryTrackValue: widget.secondaryTrackValue,
                    divisions: widget.divisions,
                    label: widget.label == null
                        ? null
                        : context.tr(widget.label!),
                    onChangeStart: (value) =>
                        _handleChangeStart(value, feedback),
                    onChanged: onChanged == null
                        ? null
                        : (value) => _handleChanged(value, feedback),
                    onChangeEnd: _handleChangeEnd,
                    semanticFormatterCallback:
                        widget.semanticFormatterCallback == null
                        ? null
                        : (value) => context.tr(
                            widget.semanticFormatterCallback!(value),
                          ),
                    focusNode: widget.focusNode,
                    autofocus: widget.autofocus,
                  ),
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
  });
  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
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
    );
  }
}
