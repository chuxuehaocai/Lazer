import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../animation/apple_spring.dart';
import '../animation/motion_snapshot.dart';
import 'cover_transition.dart';

/// Keeps only the live navigation ancestors, at stable positions in the tree.
/// Returning to a shelf therefore preserves its scroll offsets and image cache.
class RetainedContentSwitcher extends StatefulWidget {
  const RetainedContentSwitcher({
    super.key,
    required this.currentKey,
    required this.page,
    required this.retainKeys,
    this.duration = const Duration(milliseconds: 420),
    this.slideFraction = .04,
    this.expand = true,
    this.onTransitionChanged,
  });

  final String currentKey;
  final Widget page;
  final Set<String> retainKeys;
  final Duration duration;
  final double slideFraction;
  final bool expand;
  final ValueChanged<bool>? onTransitionChanged;

  @override
  State<RetainedContentSwitcher> createState() =>
      _RetainedContentSwitcherState();
}

class _RetainedPage {
  _RetainedPage(this.page);
  Widget page;
  double from = 1;
  double to = 1;
  double epoch = 0;
  SpringSimulation? spring;
  FocusNode? lastFocus;
  Widget? parkedView;
  bool get transitioning => spring != null;
}

class _RetainedContentSwitcherState extends State<RetainedContentSwitcher>
    with SingleTickerProviderStateMixin {
  final Map<String, _RetainedPage> _pages = <String, _RetainedPage>{};
  int _transitionGeneration = 0;
  late final AnimationController _motion = AnimationController.unbounded(
    vsync: this,
  )..addStatusListener(_status);

  @override
  void initState() {
    super.initState();
    // Create the ticker while the state is mounted. A route can be removed
    // before its first transition; lazy creation from dispose then loses the
    // valid vsync ancestor.
    _motion;
    _pages[widget.currentKey] = _RetainedPage(widget.page);
  }

  double _value(_RetainedPage entry) =>
      entry.spring?.x(
        (_motion.value - entry.epoch).clamp(0.0, double.infinity),
      ) ??
      entry.to;

  void _status(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _pages.removeWhere(
        (key, _) =>
            key != widget.currentKey && !widget.retainKeys.contains(key),
      );
      for (final entry in _pages.values) {
        entry.from = entry.to;
        entry.spring = null;
      }
    });
    widget.onTransitionChanged?.call(false);
    final completedKey = widget.currentKey;
    final focus = _pages[completedKey]?.lastFocus;
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.currentKey == completedKey &&
            focus.context?.mounted == true &&
            focus.canRequestFocus) {
          focus.requestFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant RetainedContentSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentKey == widget.currentKey) {
      _pages[widget.currentKey]!.page = widget.page;
      _pages.removeWhere(
        (key, entry) =>
            key != widget.currentKey &&
            !entry.transitioning &&
            !widget.retainKeys.contains(key),
      );
      return;
    }
    final focus = FocusManager.instance.primaryFocus;
    final focusedContext = focus?.context;
    var insideOldPage = false;
    focusedContext?.visitAncestorElements((element) {
      if (element.widget is Offstage &&
          element.widget.key == ValueKey<String>(oldWidget.currentKey)) {
        insideOldPage = true;
        return false;
      }
      return true;
    });
    if (insideOldPage) _pages[oldWidget.currentKey]?.lastFocus = focus;
    final velocities = <_RetainedPage, double>{};
    for (final entry in _pages.values) {
      velocities[entry] =
          entry.spring?.dx(
            (_motion.value - entry.epoch).clamp(0.0, double.infinity),
          ) ??
          0;
      entry.from = _value(entry);
      entry.to = 0;
    }
    _motion.stop();
    final incoming = _pages.putIfAbsent(
      widget.currentKey,
      () => _RetainedPage(widget.page)..from = 0,
    );
    incoming.to = 1;
    incoming.page = widget.page;
    final generation = ++_transitionGeneration;
    if (widget.duration == Duration.zero ||
        MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
      _pages.removeWhere(
        (key, _) =>
            key != widget.currentKey && !widget.retainKeys.contains(key),
      );
      for (final entry in _pages.values) {
        entry.from = entry.to;
        entry.spring = null;
      }
      widget.onTransitionChanged?.call(false);
    } else {
      final response = AppleSpring(duration: widget.duration);
      final epoch = _motion.value;
      for (final entry in _pages.values) {
        final velocity = velocities[entry] ?? 0;
        entry.epoch = epoch;
        entry.spring =
            (entry.to - entry.from).abs() < .0001 && velocity.abs() < .001
            ? null
            : response.simulation(entry.from, entry.to, velocity: velocity);
      }
      final clock = _PageSpringClock(epoch, [
        for (final entry in _pages.values)
          if (entry.spring != null) entry.spring!,
      ]);
      // Starting a simulation from didUpdateWidget can happen during layout.
      // Let the current frame finish so fake async clocks and real vsync both
      // observe a non-negative elapsed time.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _transitionGeneration) {
          _motion.animateWith(clock);
        }
      });
      widget.onTransitionChanged?.call(true);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CoverTransitionViewport(
    child: Stack(
      fit: widget.expand ? StackFit.expand : StackFit.loose,
      alignment: Alignment.topCenter,
      children: <Widget>[
        for (final item in _pages.entries) _page(item.key, item.value),
      ],
    ),
  );

  Widget _page(String key, _RetainedPage entry) {
    final current = key == widget.currentKey;
    final parked = !current && !entry.transitioning;
    // The child page was already retained; retain its inactive wrappers too.
    // They have no changing inputs while parked. Inherited theme/size changes
    // still reach their dependent elements, and revealing the page replaces
    // this view before the transition starts.
    if (parked && entry.parkedView != null) return entry.parkedView!;
    entry.parkedView = null;
    // Offstage and TickerMode stop painting and tickers, but an AnimatedWidget
    // still follows a controller owned above them. Parked history therefore
    // needs a stationary animation: otherwise every invisible ancestor rebuilds
    // its slide and updates its opacity on every subsequent navigation frame.
    final Animation<double> animation = entry.transitioning
        ? _motion.drive(_PageSpringValue(entry))
        : AlwaysStoppedAnimation<double>(entry.to);
    final view = Offstage(
      key: ValueKey<String>(key),
      offstage: !current && !entry.transitioning,
      child: TickerMode(
        enabled: current && !entry.transitioning,
        child: IgnorePointer(
          ignoring: !current,
          child: ExcludeFocus(
            excluding: !current,
            child: ExcludeSemantics(
              excluding: !current,
              child: FadeTransition(
                opacity: animation.drive(_ClampedPageOpacity()),
                child: SlideTransition(
                  position: animation.drive(
                    Tween<Offset>(
                      begin: Offset(0, widget.slideFraction),
                      end: Offset.zero,
                    ),
                  ),
                  child: MotionSnapshot(
                    animation: entry.transitioning
                        ? _motion
                        : kAlwaysCompleteAnimation,
                    child: RepaintBoundary(child: entry.page),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (parked) entry.parkedView = view;
    return view;
  }
}

class _PageSpringClock extends Simulation {
  _PageSpringClock(this.epoch, this.springs);
  final double epoch;
  final List<SpringSimulation> springs;
  @override
  double x(double time) => epoch + time;
  @override
  double dx(double time) => 1;
  @override
  bool isDone(double time) => springs.every((spring) => spring.isDone(time));
}

class _PageSpringValue extends Animatable<double> {
  _PageSpringValue(this.entry);
  final _RetainedPage entry;
  @override
  double transform(double t) =>
      entry.spring?.x((t - entry.epoch).clamp(0.0, double.infinity)) ??
      entry.to;
}

class _ClampedPageOpacity extends Animatable<double> {
  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}
