import 'package:flutter/material.dart';

import 'apple_spring.dart';

bool _reduced(BuildContext context) =>
    WidgetsBinding.instance.disableAnimations ||
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false);

Future<T?> showAppleDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(
    AppleDialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: barrierDismissible,
      barrierColor:
          barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior:
          traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      fullscreenDialog: fullscreenDialog,
      requestFocus: requestFocus,
    ),
  );
}

class AppleDialogRoute<T> extends DialogRoute<T> {
  AppleDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.fullscreenDialog,
    super.requestFocus,
  });

  @override
  Simulation createSimulation({required bool forward}) {
    final target = forward ? 1.0 : 0.0;
    final reduce = _reduced(navigator!.context);
    return AppleSpring.responsive.simulation(
      reduce ? target : controller!.value,
      target,
      velocity: reduce ? 0 : controller!.velocity,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_reduced(context)) return child;
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween(begin: 1.06, end: 1.0).animate(animation),
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

Future<T?> showAppleModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  bool? requestFocus,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final localizations = MaterialLocalizations.of(context);
  final controller = _SheetSpringController(
    vsync: navigator,
    reduceMotion: () => navigator.mounted && _reduced(navigator.context),
  );
  return navigator.push<T>(
    _AppleSheetRoute<T>(
      sheetController: controller,
      builder: builder,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      backgroundColor: backgroundColor,
      barrierLabel: barrierLabel ?? localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      elevation: elevation,
      shape: shape,
      clipBehavior: clipBehavior,
      constraints: constraints,
      modalBarrierColor:
          barrierColor ?? Theme.of(context).bottomSheetTheme.modalBarrierColor,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      anchorPoint: anchorPoint,
      requestFocus: requestFocus,
    ),
  );
}

const _sheetSpring = AppleSpring(duration: Duration(milliseconds: 350));

class _AppleSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _AppleSheetRoute({
    required _SheetSpringController sheetController,
    required super.builder,
    required super.capturedThemes,
    required super.isScrollControlled,
    super.backgroundColor,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.elevation,
    super.shape,
    super.clipBehavior,
    super.constraints,
    super.modalBarrierColor,
    super.isDismissible,
    super.enableDrag,
    super.showDragHandle,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.requestFocus,
  }) : super(
         transitionAnimationController: sheetController,
         // The controller is already the visible position, also during a drag.
         // Applying the framework's default curve would ease that coordinate twice.
         sheetAnimationStyle: const AnimationStyle(
           curve: Curves.linear,
           reverseCurve: Curves.linear,
         ),
       );

  @override
  AnimationController createAnimationController() {
    final controller = super.createAnimationController();
    willDisposeAnimationController = true;
    return controller;
  }

  @override
  Simulation createSimulation({required bool forward}) {
    final target = forward ? 1.0 : 0.0;
    final reduced = _reduced(navigator!.context);
    return _sheetSpring.simulation(
      reduced ? target : controller!.value,
      target,
      velocity: reduced ? 0 : controller!.velocity,
    );
  }
}

class _SheetSpringController extends AnimationController {
  _SheetSpringController({required super.vsync, required this.reduceMotion})
    : super(
        duration: _sheetSpring.duration,
        reverseDuration: _sheetSpring.duration,
      );

  final bool Function() reduceMotion;
  final Stopwatch _clock = Stopwatch()..start();
  int? _lastDragUs;
  double _dragVelocity = 0;

  @override
  set value(double next) {
    final now = _clock.elapsedMicroseconds;
    final previous = _lastDragUs;
    _dragVelocity =
        previous != null && now > previous && now - previous < 100000
        ? (next - value) * 1000000 / (now - previous)
        : 0;
    _lastDragUs = now;
    super.value = next;
  }

  @override
  TickerFuture forward({double? from}) {
    if (from != null) value = from;
    final recent =
        _lastDragUs != null &&
        _clock.elapsedMicroseconds - _lastDragUs! < 100000;
    final initialVelocity = recent ? _dragVelocity : velocity;
    _lastDragUs = null;
    return springTo(
      1,
      spring: _sheetSpring,
      velocity: initialVelocity,
      reduceMotion: reduceMotion(),
    );
  }

  @override
  TickerFuture fling({
    double velocity = 1,
    SpringDescription? springDescription,
    AnimationBehavior? animationBehavior,
  }) {
    _lastDragUs = null;
    return springTo(
      velocity < 0 ? 0 : 1,
      spring: _sheetSpring,
      velocity: velocity,
      reduceMotion: reduceMotion(),
    );
  }

  @override
  void dispose() {
    _clock.stop();
    super.dispose();
  }
}
