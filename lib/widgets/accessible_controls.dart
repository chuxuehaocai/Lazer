import 'dart:async';

import 'package:flutter/material.dart';
import '../interaction/app_haptics.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'interaction_feedback.dart';

/// Keep a control's OverlayPortal and its anchor in the same semantics island.
/// Flutter 3.47 can otherwise serialize orphan nodes during route transitions
/// and tooltip changes (flutter/flutter#190357 and #182444).
/// This preserves the real control's semantics, focus and keyboard actions.
class SemanticsPortal extends StatelessWidget {
  const SemanticsPortal({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
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

  @override
  Widget build(BuildContext context) {
    final AppState? state = widget.detentFeedback
        ? InteractionFeedback.of(context)
        : null;
    final ValueChanged<double>? onChanged = widget.onChanged;
    return SemanticsPortal(
      child: MergeSemantics(
        child: Semantics(
          label: widget.semanticLabel == null
              ? null
              : context.tr(widget.semanticLabel!),
          child: Slider(
            value: widget.value,
            min: widget.min,
            max: widget.max,
            secondaryTrackValue: widget.secondaryTrackValue,
            divisions: widget.divisions,
            label: widget.label == null ? null : context.tr(widget.label!),
            onChangeStart: widget.detentFeedback
                ? (value) {
                    _detents = SliderDetents(
                      min: widget.min,
                      max: widget.max,
                      steps: widget.divisions,
                    );
                    _detents!.begin(value);
                    if (state != null) unawaited(state.feedback(detent: true));
                    widget.onChangeStart?.call(value);
                  }
                : widget.onChangeStart,
            onChanged: !widget.detentFeedback || onChanged == null
                ? onChanged
                : (value) {
                    final detents = _detents;
                    if (detents != null &&
                        state != null &&
                        detents.update(value)) {
                      unawaited(
                        state.feedback(
                          detent: true,
                          boundary: value <= widget.min || value >= widget.max,
                        ),
                      );
                    }
                    onChanged(value);
                  },
            onChangeEnd: widget.detentFeedback
                ? (value) {
                    _detents?.end();
                    _detents = null;
                    widget.onChangeEnd?.call(value);
                  }
                : widget.onChangeEnd,
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
      child: IconButton(
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
    );
  }
}
