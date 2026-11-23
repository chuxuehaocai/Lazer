import 'build_safe_state.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';

import '../animation/apple_spring.dart';
import '../animation/motion_snapshot.dart';
import 'cover_transition.dart';
import 'shared_browse_background.dart';

/// Keeps only the live navigation ancestors, at stable positions in the tree.
/// Returning to a shelf therefore preserves its scroll offsets and image cache.
class RetainedContentSwitcher extends StatefulWidget {
  const RetainedContentSwitcher({
    super.key,
    required this.currentKey,
    required this.page,
    required this.retainKeys,
    this.maxRetainedPages = 9,
    this.duration = const Duration(milliseconds: 420),
    this.slideFraction = .04,
    this.expand = true,
    this.onTransitionChanged,
    this.backProgress,
    this.backTargetKey,
    this.backCommitted = false,
  }) : assert(maxRetainedPages >= 2);

  final String currentKey;
  final Widget page;
  final Set<String> retainKeys;

  /// Includes the current page and its retained navigation ancestors. At most
  /// one additional, outgoing page may exist while a switch is running.
  final int maxRetainedPages;
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

  /// The backdrop under this switcher, frozen for the running preview.
  ///
  /// Owned here: it is captured when a preview needs it and released as soon
  /// as the gesture ends, so a drag never keeps a full-window texture alive
  /// between gestures.
  ui.Image? _previewFrame;
  int _transitionGeneration = 0;
  bool _reportedMoving = false;
  late final AnimationController _motion = AnimationController.unbounded(
    vsync: this,
  )..addStatusListener(_status);

  /// Upper bound on one page switch. A spring that stalls (a dropped frame, a
  /// platform lifecycle pause, or a retarget that never produced a tick) would
  /// otherwise leave the outgoing page painted over the incoming one forever:
  /// the reported home-page ghost was the 每日推荐 page stuck half faded.
  Timer? _settleWatchdog;

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
    widget.backProgress?.addListener(_onBackProgress);
  }

  void _onBackProgress() {
    if (widget.backProgress?.value != null) return;
    final ui.Image? frame = _previewFrame;
    if (frame == null) return;
    _previewFrame = null;
    // This frame still paints the preview; the rebuild the notifier just
    // scheduled is the one that stops using the texture.
    WidgetsBinding.instance.addPostFrameCallback((_) => frame.dispose());
    if (mounted) setState(() {});
  }

  /// The frozen canvas for the running preview, captured on first use.
  ///
  /// Only the page that is leaving needs it, and only while a page preview is
  /// on screen, so nothing is captured for the player's own overlay gesture.
  ui.Image? _previewBackdrop(BuildContext context) {
    final ui.Image? captured = _previewFrame;
    if (captured != null) return captured;
    if (!mounted) return null;
    final RenderObject? region = this.context.findRenderObject();
    final ui.Image? frame = BrowseBackgroundScope.maybeOf(
      this.context,
    )?.capture?.call(region is RenderBox ? region : null);
    return _previewFrame = frame;
  }

  double _value(_RetainedPage entry) =>
      entry.spring?.x(
        (_motion.value - entry.epoch).clamp(0.0, double.infinity),
      ) ??
      entry.to;

  /// Keep the root and nearest ancestors under a hard budget. Intermediate
  /// outgoing pages from interrupted switches are no longer visible history;
  /// retaining all their springs lets rapid navigation accumulate full pages.
  void _prunePages({String? outgoingKey}) {
    final keep = <String>{widget.currentKey};
    final target = widget.backTargetKey;
    if (target != null && _pages.containsKey(target)) keep.add(target);
    final requested = widget.retainKeys.where(_pages.containsKey).toList();
    if (requested.isNotEmpty && keep.length < widget.maxRetainedPages) {
      keep.add(requested.first);
    }
    for (final key in requested.reversed) {
      if (keep.length >= widget.maxRetainedPages) break;
      keep.add(key);
    }
    if (outgoingKey != null) keep.add(outgoingKey);
    _pages.removeWhere((key, _) => !keep.contains(key));
  }

  void _settlePages() {
    _prunePages();
    for (final entry in _pages.values) {
      entry
        ..from = entry.to
        ..spring = null
        ..parkedView = null;
    }
  }

  void _status(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    _settleWatchdog?.cancel();
    _settleWatchdog = null;
    setState(() {
      _settlePages();
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

  /// Settles a switch even if its spring never reports completion.
  void _armSettleWatchdog() {
    _settleWatchdog?.cancel();
    if (widget.duration <= Duration.zero) return;
    _settleWatchdog = Timer(
      widget.duration * 4 + const Duration(milliseconds: 250),
      () {
        if (!mounted) return;
        _settleWatchdog = null;
        setState(() {
          _settlePages();
        });
        _motion.stop();
        _report(false);
      },
    );
  }

  @override
  void didUpdateWidget(covariant RetainedContentSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backProgress != widget.backProgress) {
      oldWidget.backProgress?.removeListener(_onBackProgress);
      widget.backProgress?.addListener(_onBackProgress);
    }
    if (oldWidget.currentKey == widget.currentKey) {
      _pages[widget.currentKey]!.page = widget.page;
      final outgoing = _pages.entries
          .where(
            (item) => item.key != widget.currentKey && item.value.transitioning,
          )
          .lastOrNull;
      _prunePages(outgoingKey: outgoing?.key);
      return;
    }
    if (oldWidget.backTargetKey == widget.currentKey && widget.backCommitted) {
      // The interactive preview already painted the complete return. Keep
      // those exact retained elements and finish without a second transition.
      _settleWatchdog?.cancel();
      _settleWatchdog = null;
      _transitionGeneration++;
      _motion.stop();
      // A destination can have been evicted by the retention budget.
      _pages
              .putIfAbsent(widget.currentKey, () => _RetainedPage(widget.page))
              .page =
          widget.page;
      _prunePages();
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
    // The player can dismiss while its focused subtree is being removed. In
    // that frame the FocusNode still exposes its old context, but walking its
    // ancestors would query a deactivated element and throw during a route
    // switch. Only restore focus when the context is still mounted.
    if (focusedContext?.mounted == true) {
      try {
        focusedContext!.visitAncestorElements((element) {
          if (element.widget is Offstage &&
              element.widget.key == ValueKey<String>(oldWidget.currentKey)) {
            insideOldPage = true;
            return false;
          }
          return true;
        });
      } on FlutterError {
        // A focus node can retain a deactivated context for this frame while
        // an overlay is being removed. It cannot be used to restore focus.
      }
    }
    if (insideOldPage) _pages[oldWidget.currentKey]?.lastFocus = focus;
    final velocities = <_RetainedPage, double>{};
    for (final item in _pages.entries) {
      final entry = item.value;
      if (item.key != oldWidget.currentKey && item.key != widget.currentKey) {
        entry
          ..from = 0
          ..to = 0
          ..spring = null
          ..parkedView = null;
      }
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
    _prunePages(outgoingKey: oldWidget.currentKey);
    final generation = ++_transitionGeneration;
    if (widget.duration <= Duration.zero ||
        MediaQuery.disableAnimationsOf(context)) {
      _settleWatchdog?.cancel();
      _settleWatchdog = null;
      _motion.stop();
      _settlePages();
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
      _armSettleWatchdog();
    }
  }

  @override
  void dispose() {
    widget.backProgress?.removeListener(_onBackProgress);
    _previewFrame?.dispose();
    _previewFrame = null;
    _settleWatchdog?.cancel();
    _settleWatchdog = null;
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
        // Only parked pages stay muted. The incoming page is fully visible
        // while the spring runs, and muting its tickers froze spinners and
        // entrance animations for the whole switch — very visible at slow
        // animation speeds. The outgoing page is raster-snapshotted instead.
        enabled: current || preview,
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
                      child: _previewSurface(
                        context,
                        preview: preview,
                        current: current,
                        child: MotionSnapshot(
                          animation: entry.transitioning
                              ? _motion
                              : kAlwaysCompleteAnimation,
                          snapshotForward: !current,
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

  /// The opaque layer the outgoing page needs while it covers the destination.
  ///
  /// Only the page that is leaving gets one: the page being revealed must stay
  /// transparent so the shared backdrop below the navigator keeps painting
  /// through it. The leaving page gets the same backdrop, captured when the
  /// gesture started, so the uncovered edges still meet a matching canvas
  /// instead of a flat surface colour.
  Widget _previewSurface(
    BuildContext context, {
    required bool preview,
    required bool current,
    required Widget child,
  }) {
    if (!preview) {
      // Unchanged outside a gesture: a transparent box keeps the page's own
      // hit-test surface exactly as it was.
      return ColoredBox(color: Colors.transparent, child: child);
    }
    if (!current) return child;
    final ui.Image? frame = _previewBackdrop(context);
    if (frame == null) {
      // No canvas to freeze (mica is composited by the window manager, and a
      // host may paint none at all): keep the destination hidden the old way.
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: child,
      );
    }
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: ExcludeSemantics(
            child: RawImage(
              key: const ValueKey<String>('browse-preview-backdrop'),
              image: frame,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
        child,
      ],
    );
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
  // Both pages share a transparent canvas. Their complementary springs must
  // fade through it instead of painting two sets of text at the same time.
  double transform(double t) => ((t - .5) * 2).clamp(0.0, 1.0);
}
