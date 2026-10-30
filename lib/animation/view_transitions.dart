import 'package:flutter/material.dart';

import 'motion_snapshot.dart';

abstract final class ViewMotion {
  static const curve = Cubic(.22, 1, .36, 1);
  static const duration = Duration(milliseconds: 320);
}

/// Small compositor-only movement shared by forms, tabs and embedded views.
class ViewTransitionSwitcher extends StatelessWidget {
  const ViewTransitionSwitcher({
    super.key,
    required this.child,
    this.expand = true,
  });
  final Widget child;
  final bool expand;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : ViewMotion.duration,
    switchInCurve: ViewMotion.curve,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(
      fit: expand ? StackFit.expand : StackFit.loose,
      alignment: Alignment.topCenter,
      children: [
        if (previous.isNotEmpty)
          ExcludeFocus(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: TickerMode(enabled: false, child: previous.last),
              ),
            ),
          ),
        ?current,
      ],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .025),
          end: Offset.zero,
        ).animate(animation),
        child: MotionSnapshot(animation: animation, child: child),
      ),
    ),
    child: child,
  );
}

class LazerPageTransitionsBuilder extends PageTransitionsBuilder {
  const LazerPageTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final motion = animation.drive(CurveTween(curve: ViewMotion.curve));
    return FadeTransition(
      opacity: motion,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(.035, 0),
          end: Offset.zero,
        ).animate(motion),
        child: MotionSnapshot(animation: animation, child: child),
      ),
    );
  }
}
