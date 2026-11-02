import 'package:flutter/material.dart';

import 'interaction_feedback.dart';

// These facades retain the real Material button for semantics, focus, shortcuts
// and gesture cancellation. Only visual press feedback is supplied by us.
enum _ButtonKind { text, filled, tonal, outlined, elevated }

class _SpringButton extends StatelessWidget {
  const _SpringButton({
    super.key,
    required this.kind,
    required this.onPressed,
    required this.child,
    this.icon,
    this.isIcon = false,
    this.iconAlignment = IconAlignment.start,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
  });

  final _ButtonKind kind;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip? clipBehavior;
  final Widget child;
  final Widget? icon;
  final bool isIcon;
  final IconAlignment iconAlignment;

  @override
  Widget build(BuildContext context) => SpringPress(
    builder: (context, states) {
      if (kind == _ButtonKind.text) {
        if (isIcon) {
          return TextButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: states,
            icon: icon,
            label: child,
            iconAlignment: iconAlignment,
          );
        }
        return TextButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior,
          statesController: states,
          child: child,
        );
      }
      if (kind == _ButtonKind.filled) {
        if (isIcon) {
          return FilledButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: states,
            icon: icon,
            label: child,
            iconAlignment: iconAlignment,
          );
        }
        return FilledButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior,
          statesController: states,
          child: child,
        );
      }
      if (kind == _ButtonKind.tonal) {
        if (isIcon) {
          return FilledButton.tonalIcon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: states,
            icon: icon,
            label: child,
            iconAlignment: iconAlignment,
          );
        }
        return FilledButton.tonal(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior,
          statesController: states,
          child: child,
        );
      }
      if (kind == _ButtonKind.outlined) {
        if (isIcon) {
          return OutlinedButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: states,
            icon: icon,
            label: child,
            iconAlignment: iconAlignment,
          );
        }
        return OutlinedButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior,
          statesController: states,
          child: child,
        );
      }
      if (kind == _ButtonKind.elevated) {
        if (isIcon) {
          return ElevatedButton.icon(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: states,
            icon: icon,
            label: child,
            iconAlignment: iconAlignment,
          );
        }
        return ElevatedButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          onHover: onHover,
          onFocusChange: onFocusChange,
          style: style,
          focusNode: focusNode,
          autofocus: autofocus,
          clipBehavior: clipBehavior,
          statesController: states,
          child: child,
        );
      }
      throw StateError('Unsupported button kind');
    },
  );
}

class SpringTextButton extends _SpringButton {
  const SpringTextButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.text);

  const SpringTextButton.icon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.iconAlignment,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.text, child: label, isIcon: true);
}

class SpringFilledButton extends _SpringButton {
  const SpringFilledButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.filled);

  const SpringFilledButton.icon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.iconAlignment,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.filled, child: label, isIcon: true);

  const SpringFilledButton.tonal({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.tonal);

  const SpringFilledButton.tonalIcon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.iconAlignment,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.tonal, child: label, isIcon: true);
}

class SpringOutlinedButton extends _SpringButton {
  const SpringOutlinedButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.outlined);

  const SpringOutlinedButton.icon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.iconAlignment,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.outlined, child: label, isIcon: true);
}

class SpringElevatedButton extends _SpringButton {
  const SpringElevatedButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.elevated);

  const SpringElevatedButton.icon({
    super.key,
    required super.onPressed,
    required Widget label,
    super.icon,
    super.iconAlignment,
    super.onLongPress,
    super.onHover,
    super.onFocusChange,
    super.style,
    super.focusNode,
    super.autofocus,
    super.clipBehavior,
  }) : super(kind: _ButtonKind.elevated, child: label, isIcon: true);
}
