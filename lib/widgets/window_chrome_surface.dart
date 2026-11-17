import 'package:flutter/material.dart';

const double kWindowChromeHeight = 40.0;
const double kWindowChromeButtonWidth = 46.0;

/// The shared surface for floating caption and player-action capsules.
class WindowChromeSurface extends StatelessWidget {
  const WindowChromeSurface({
    super.key,
    required this.child,
    this.inline = true,
  });

  final Widget child;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    if (!inline) return child;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius radius = BorderRadius.circular(kWindowChromeHeight / 2);
    return ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: .045),
          borderRadius: radius,
          border: Border.all(
            color: scheme.onSurface.withValues(alpha: .08),
            width: .5,
          ),
        ),
        child: child,
      ),
    );
  }
}
