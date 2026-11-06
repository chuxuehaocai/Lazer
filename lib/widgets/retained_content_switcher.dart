import 'build_safe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
    this.backProgress,
    this.backTargetKey,
    this.backCommitted = false,
  });

  final String currentKey;
  final Widget page;
  final Set<String> retainKeys;
  final Duration duration;
  final double slideFraction;
  final bool expand;
  final ValueChanged<bool>? onTransitionChanged;
  final ValueListenable<double?>? backProgress;
  final String? backTargetKey;
  final bool backCommitted;

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
    with
        SingleTickerProviderStateMixin,
        BuildSafeState<RetainedContentSwitcher> {
  final Map<String, _RetainedPage> _pages = <String, _RetainedPage>{};
  int _transitionGeneration = 0;
  bool _reportedMoving = false;
  late final AnimationController _motion = AnimationController.unbounded(
    vsync: this,
  )..addStatusListener(_status);

  /// Every transition report goes through here so [dispose] knows whether a
  /// `false` is still owed.
  void _report(bool moving) {
    _reportedMoving = moving;
    widget.onTransitionChanged?.call(moving);
  }

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
    _report(false);
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
    if (oldWidget.backTargetKey == widget.currentKey && widget.backCommitted) {
      // The interactive preview already painted the complete return. Keep
      // those exact retained elements and finish without a second transition.
      _transitionGeneration++;
      _motion.stop();
      _pages[widget.currentKey]!.page = widget.page;
      _pages.removeWhere(
        (key, _) =>
            key != widget.currentKey && !widget.retainKeys.contains(key),
      );
      for (final item in _pages.entries) {
        item.value
          ..from = item.key == widget.currentKey ? 1 : 0
          ..to = item.key == widget.currentKey ? 1 : 0
          ..spring = null
          ..parkedView = null;
      }
      _report(false);
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
      _report(false);
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
      _report(true);
    }
  }

  @override
  void dispose() {
    // The shell replaces this element outright when a layout-mode change or a
    // resize across the breakpoint puts the content at a different place in the
    // tree. The completion that would have reported the end of the switch never
    // runs then, and the shell's switching flag is only ever set, never
    // cleared: it freezes the ambient backdrop's TickerMode, disables the
    // content back gesture and drops every structural state report until the
    // next navigation. Owe the report and pay it after the frame, so no
    // listener is notified from inside an unmount.
    if (_reportedMoving) {
      _reportedMoving = false;
      final report = widget.onTransitionChanged;
      if (report != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => report(false));
      }
    }
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.backProgress;
    if (progress == null) return _stack(null);
    return ValueListenableBuilder<double?>(
      valueListenable: progress,
      builder: (context, value, _) => _stack(value),
    );
  }

  Widget _stack(double? backProgress) => CoverTransitionViewport(
    child: Stack(
      fit: widget.expand ? StackFit.expand : StackFit.loose,
      alignment: Alignment.topCenter,
      children: <Widget>[
        for (final item in _pages.entries)
          if (backProgress == null ||
              item.key != widget.currentKey && item.key != widget.backTargetKey)
            _page(item.key, item.value, backProgress),
        if (backProgress != null) ...[
          if (_pages[widget.backTargetKey] case final target?)
            _page(widget.backTargetKey!, target, backProgress),
          _page(widget.currentKey, _pages[widget.currentKey]!, backProgress),
        ],
      ],
    ),
  );

  Widget _page(String key, _RetainedPage entry, double? backProgress) {
    final current = key == widget.currentKey;
    // A preview needs a destination. The player's back gesture reports progress
    // with no target key, because it dismisses the player overlay rather than a
    // browse page: the browse stack underneath is the backdrop the player is
    // uncovering, so it must keep its own animation, position and opacity. The
    // `current` disjunct alone used to make it a preview, which slid it a full
    // width on iOS and faded it out on Android while the player came down.
    final preview =
        backProgress != null &&
        widget.backTargetKey != null &&
        (current || key == widget.backTargetKey);
    final parked = !current && !entry.transitioning && !preview;
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
      offstage: parked,
      child: TickerMode(
        enabled: current && !entry.transitioning && !preview,
        child: IgnorePointer(
          ignoring: !current,
          child: ExcludeFocus(
            excluding: !current,
            child: ExcludeSemantics(
              excluding: !current,
              child: FractionalTranslation(
                translation: !preview || MediaQuery.disableAnimationsOf(context)
                    ? Offset.zero
                    : Theme.of(context).platform == TargetPlatform.iOS
                    ? Offset(
                        (current ? backProgress : -.3 * (1 - backProgress)) *
                            (Directionality.of(context) == TextDirection.rtl
                                ? -1
                                : 1),
                        0,
                      )
                    : Offset(current ? .035 * backProgress : 0, 0),
                child: Transform.scale(
                  scale:
                      preview &&
                          current &&
                          Theme.of(context).platform ==
                              TargetPlatform.android &&
                          !MediaQuery.disableAnimationsOf(context)
                      ? 1 - .08 * backProgress
                      : 1,
                  child: FadeTransition(
                    opacity: preview
                        ? current &&
                                  Theme.of(context).platform ==
                                      TargetPlatform.android &&
                                  !MediaQuery.disableAnimationsOf(context)
                              ? AlwaysStoppedAnimation(
                                  ((1 - backProgress) / .25).clamp(0.0, 1.0),
                                )
                              : kAlwaysCompleteAnimation
                        : animation.drive(_ClampedPageOpacity()),
                    child: SlideTransition(
                      position: preview
                          ? const AlwaysStoppedAnimation(Offset.zero)
                          : animation.drive(
                              Tween<Offset>(
                                begin: Offset(0, widget.slideFraction),
                                end: Offset.zero,
                              ),
                            ),
                      child: ColoredBox(
                        color: preview
                            ? Theme.of(context).colorScheme.surface
                            : Colors.transparent,
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
