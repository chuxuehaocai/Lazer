import 'build_safe_state.dart';
import 'package:flutter/material.dart';
import '../animation/view_transitions.dart';
import 'package:flutter/services.dart';
import '../animation/apple_spring.dart';
import '../l10n/app_localizations.dart';
import '../navigation/system_back_gesture.dart';
import '../theme/apple_design.dart';

import 'accessible_controls.dart';

/// Keeps desktop settings inside the shell, including its navigation and player.
class SettingsDetailHost extends StatefulWidget {
  const SettingsDetailHost({
    super.key,
    required this.compact,
    required this.child,
  });

  final bool compact;
  final Widget child;

  static bool isEmbedded(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SettingsDetailScope>()
          ?.close !=
      null;

  static void open(
    BuildContext context, {
    required WidgetBuilder page,
    required WidgetBuilder view,
  }) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_SettingsDetailScope>();
    if (scope?.open case final open?) {
      open(view);
    } else {
      Navigator.of(context).push<void>(ApplePageRoute(builder: page));
    }
  }

  @override
  State<SettingsDetailHost> createState() => _SettingsDetailHostState();
}

/// One subview opened inside the settings host.
///
/// The host keeps a stack rather than a single slot: 插件管理 opens 插件市场 on
/// top of itself and Back returns one level at a time, so both moves need the
/// same spring the first push already had.
class _DetailPage {
  _DetailPage(this.builder) : id = _nextId++;
  static int _nextId = 0;
  final int id;
  final WidgetBuilder builder;
}

class _SettingsDetailHostState extends State<SettingsDetailHost>
    with TickerProviderStateMixin, BuildSafeState<SettingsDetailHost> {
  final _storage = PageStorageBucket();
  final _backProgress = ValueNotifier<double?>(null);

  /// Open subviews; the last entry is the page on screen.
  final List<_DetailPage> _details = <_DetailPage>[];

  /// The subview that is leaving while a nested push or pop runs.
  _DetailPage? _leaving;

  /// One local-history entry for the whole detail session; Back inside the
  /// stack pops a level, and only the last level gives the entry back.
  LocalHistoryEntry? _history;

  /// Set while the host is torn down, so callbacks stop touching state.
  bool _disposing = false;

  /// Direction of the running nested motion: a push presents the new page, a
  /// pop hands the screen back to the one underneath.
  bool _pushing = true;

  @override
  void initState() {
    super.initState();
    _backProgress.addListener(_backChanged);
  }

  void _backChanged() {
    final progress = _backProgress.value;
    if (progress != null &&
        _history != null &&
        !MediaQuery.disableAnimationsOf(context)) {
      _transition.value = 1 - progress;
    }
  }

  late final _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addStatusListener(_transitionChanged);
  // Fade through the shared canvas so the two sets of controls never blend.
  late final _overviewOpacity = ReverseAnimation(
    _transition.drive(CurveTween(curve: const Interval(0, .35))),
  );
  late final _detailOpacity = _transition.drive(
    CurveTween(curve: const Interval(.35, 1)),
  );
  late final _overviewPosition = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-.025, 0),
  ).animate(_transition);
  late final _detailPosition = Tween<Offset>(
    begin: const Offset(.035, 0),
    end: Offset.zero,
  ).animate(_transition);

  /// Nested push/pop between two open subviews.
  ///
  /// 1 means "the newer page is presented"; the first push leaves it at rest
  /// there, so a page opened straight from the overview never carries a stack
  /// offset of its own.
  late final _swap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  )..addStatusListener(_swapChanged);

  /// How far the nested motion has travelled, in either direction.
  double get _swapProgress => _pushing ? _swap.value : 1 - _swap.value;

  /// The page handing over the screen leaves the way the first push sent the
  /// overview away: to the left when it is replaced, back to the right (where
  /// it came from) when it is dismissed.
  Offset get _leavingOffset => _pushing
      ? Offset(-.025 * _swapProgress, 0)
      : Offset(.035 * _swapProgress, 0);

  /// The page taking over arrives from the opposite side.
  Offset get _enteringOffset => _pushing
      ? Offset(.035 * (1 - _swapProgress), 0)
      : Offset(-.025 * (1 - _swapProgress), 0);

  double get _leavingOpacity => ((.4 - _swapProgress) / .4).clamp(0.0, 1.0);

  double get _enteringOpacity => ((_swapProgress - .55) / .45).clamp(0.0, 1.0);

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  void _swapChanged(AnimationStatus status) {
    if (!mounted || _disposing || _leaving == null) return;
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    setState(() => _leaving = null);
  }

  void _open(WidgetBuilder builder) {
    if (_details.isEmpty) {
      if (_history == null) {
        _history = LocalHistoryEntry(onRemove: _closed);
        ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
      }
      setState(() {
        _leaving = null;
        _pushing = true;
        _swap.value = 1;
        _details.add(_DetailPage(builder));
      });
      if (_reduceMotion) {
        _transition.value = 1;
      } else {
        _transition.springTo(1, spring: AppleSpring.responsive);
      }
      return;
    }
    // A subview is already open: put the new one on top of it with the same
    // motion instead of swapping the slot on a single frame.
    _swap.stop();
    final bool reduce = _reduceMotion;
    setState(() {
      _pushing = true;
      _swap.value = 0;
      // The open subview stays in the stack: it is the page underneath, and
      // keeping it mounted is what preserves its scroll and its fields.
      _leaving = _details.last;
      _details.add(_DetailPage(builder));
    });
    if (reduce) {
      _swap.value = 1;
      setState(() => _leaving = null);
    } else {
      _swap.springTo(1, spring: AppleSpring.responsive);
    }
  }

  void _close() {
    if (_details.length > 1) {
      // Back inside the stack: hand the screen to the page underneath.
      _swap.stop();
      final bool reduce = _reduceMotion;
      setState(() {
        _pushing = false;
        _swap.value = 1;
        _leaving = _details.removeLast();
      });
      if (reduce) {
        _swap.value = 0;
        setState(() => _leaving = null);
      } else {
        _swap.springTo(0, spring: AppleSpring.responsive);
      }
      return;
    }
    _history?.remove();
  }

  void _closed() {
    _history = null;
    if (!mounted || _disposing) return;
    final immediate =
        MediaQuery.disableAnimationsOf(context) ||
        (_backProgress.value ?? 0) >= 1;
    setState(() {
      _swap.stop();
      _swap.value = 0;
      _leaving = null;
      if (immediate || _transition.isDismissed) _details.clear();
    });
    if (immediate) {
      _transition.value = 0;
    } else {
      _transition.springTo(0, spring: AppleSpring.responsive);
    }
  }

  void _transitionChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        _history == null &&
        _details.isNotEmpty &&
        mounted &&
        !_disposing) {
      setState(() => _details.clear());
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _history?.remove();
    _backProgress.dispose();
    _swap.dispose();
    _transition.dispose();
    super.dispose();
  }

  /// Keeps the overview mounted so its scroll and controls do not have to
  /// restore themselves on the first return frame.
  Widget _overviewLayer({required bool active}) => AnimatedBuilder(
    animation: _transition,
    builder: (context, child) => Offstage(
      offstage: _overviewOpacity.value == 0,
      child: TickerMode(enabled: _overviewOpacity.value != 0, child: child!),
    ),
    child: ExcludeFocus(
      excluding: active,
      child: ExcludeSemantics(
        excluding: active,
        child: IgnorePointer(
          ignoring: active,
          child: FadeTransition(
            opacity: _overviewOpacity,
            child: SlideTransition(
              position: _overviewPosition,
              child: RepaintBoundary(child: widget.child),
            ),
          ),
        ),
      ),
    ),
  );

  /// One subview: the visible page follows the overview↔detail spring, and a
  /// nested push or pop adds the stack motion on top of it.
  ///
  /// Keyed by page identity so the Stack moves this subtree between the
  /// "leaving" and "current" slots instead of rebuilding it: a nested push
  /// must not reset the scroll position or the fields of the page underneath.
  Widget _detailLayer(
    _DetailPage page, {
    required _DetailPage? detail,
    required bool active,
    required bool leaving,
  }) => KeyedSubtree(
    key: ValueKey<int>(page.id),
    child: AnimatedBuilder(
      animation: _swap,
      builder: (BuildContext context, Widget? child) {
        final bool isLeaving = leaving;
        final bool isDetail = page == detail;
        final bool moving = _leaving != null;

        final double nested;
        final Offset offset;

        if (isLeaving) {
          nested = _leavingOpacity;
          offset = _leavingOffset;
        } else if (isDetail) {
          nested = moving ? _enteringOpacity : 1.0;
          offset = moving ? _enteringOffset : Offset.zero;
        } else {
          nested = 0.0;
          offset = Offset.zero;
        }

        final bool buried = !isLeaving && !isDetail;

        return Offstage(
          offstage: buried,
          child: TickerMode(
            enabled: !buried,
            child: Opacity(
              opacity: nested,
              child: FractionalTranslation(translation: offset, child: child),
            ),
          ),
        );
      },
      child: ExcludeFocus(
        excluding: !active,
        child: ExcludeSemantics(
          excluding: !active,
          child: IgnorePointer(
            ignoring: !active,
            child: FadeTransition(
              opacity: _detailOpacity,
              child: SlideTransition(
                position: _detailPosition,
                child: RepaintBoundary(
                  // Retain the embedded scope until the exit has finished, never
                  // replacing it with a Scaffold.
                  child: _SettingsDetailScope(
                    key: ValueKey<int>(page.id),
                    open: _open,
                    close: _close,
                    child: Focus(
                      autofocus: active,
                      child: Builder(builder: page.builder),
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

  @override
  Widget build(BuildContext context) {
    final _DetailPage? detail = _details.isEmpty ? null : _details.last;
    final _DetailPage? leaving = _leaving;
    final bool active = _history != null;
    return SystemBackGesture(
      canStart: () =>
          mounted &&
          _history != null &&
          _transition.isCompleted &&
          !_swap.isAnimating &&
          (ModalRoute.of(context)?.isCurrent ?? false),
      progress: _backProgress,
      onStart: _transition.stop,
      onCommit: _close,
      child: _SettingsDetailScope(
        open: widget.compact ? null : _open,
        close: null,
        child: CallbackShortcuts(
          bindings: {
            if (active)
              const SingleActivator(LogicalKeyboardKey.escape): _close,
          },
          child: PageStorage(
            bucket: _storage,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _overviewLayer(active: active),
                  // The whole stack stays mounted, so coming back to a subview
                  // restores it exactly where the listener left it.
                  for (final _DetailPage page in _details)
                    _detailLayer(
                      page,
                      detail: detail,
                      active: active && page == detail,
                      leaving: page == leaving,
                    ),
                  // A popped page paints on top of the one it hands back to.
                  if (leaving != null && !_details.contains(leaving))
                    _detailLayer(
                      leaving,
                      detail: detail,
                      active: false,
                      leaving: true,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsDetailScope extends InheritedWidget {
  const _SettingsDetailScope({
    super.key,
    required this.open,
    required this.close,
    required super.child,
  });
  final ValueChanged<WidgetBuilder>? open;
  final VoidCallback? close;

  @override
  bool updateShouldNotify(_SettingsDetailScope oldWidget) =>
      open != oldWidget.open || close != oldWidget.close;
}

/// The controls are shared; only mobile needs a route-sized scaffold.
class SettingsDetailScaffold extends StatelessWidget {
  const SettingsDetailScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.headerTitle = false,
  });
  final String title;
  final Widget child;
  final List<Widget> actions;

  /// Paints [title] in the header row instead of only naming the page on the
  /// overview. Off by default: category pages already show a large page title
  /// inside their scroll view.
  final bool headerTitle;

  @override
  Widget build(BuildContext context) {
    final close = context
        .dependOnInheritedWidgetOfExactType<_SettingsDetailScope>()
        ?.close;
    final Widget? trailing = actions.isEmpty
        ? null
        : Wrap(spacing: 8, children: actions);
    if (close == null) {
      final bool canPop = Navigator.of(context).canPop();
      final bool hasTopBar = canPop || trailing != null || headerTitle;
      return _DetailRouteSurface(
        child: SafeArea(
          child: Stack(
            children: <Widget>[
              if (hasTopBar)
                Positioned(
                  top: 0,
                  left: 8,
                  right: 8,
                  child: Row(
                    children: <Widget>[
                      if (canPop)
                        AccessibleIconButton(
                          key: const ValueKey('settings-detail-back'),
                          tooltip: '返回',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                      if (headerTitle)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              context.tr(title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    color: AppleSemanticColors.of(
                                      context,
                                    ).label,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      ?trailing,
                    ],
                  ),
                ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(top: hasTopBar ? 56 : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[Expanded(child: child)],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Material(
      key: const ValueKey('settings-detail-material'),
      // The shared browse canvas lives below the navigator. An opaque material
      // here painted the theme background over it, so every secondary settings
      // page turned into a flat black sheet in the dark theme even while the
      // configured backdrop was running.
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inset = constraints.maxWidth < 600 ? 20.0 : 32.0;
          return Column(
            key: const ValueKey('settings-detail-subview'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(inset - 12, 0, inset, 0),
                child: Row(
                  children: [
                    AccessibleIconButton(
                      key: const ValueKey('settings-detail-back'),
                      tooltip: '返回',
                      onPressed: close,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    if (headerTitle)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            context.tr(title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: AppleSemanticColors.of(context).label,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    ?trailing,
                  ],
                ),
              ),
              // Page content owns its heading; the shared chrome only keeps
              // navigation and actions above it.
              const SizedBox(height: 8),
              Expanded(child: child),
            ],
          );
        },
      ),
    );
  }
}

/// A pushed settings page shares the browse canvas, but keeps an opaque veil
/// only while the route is still moving. Without it the outgoing page shows
/// through the incoming one during the push; if it stayed after the spring
/// settles, the configured backdrop would never be visible.
class _DetailRouteSurface extends StatelessWidget {
  const _DetailRouteSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Animation<double>? animation = ModalRoute.of(context)?.animation;
    final Color canvas = AppleSemanticColors.of(context).background;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (animation != null)
          AnimatedBuilder(
            animation: animation,
            builder: (BuildContext context, Widget? _) => IgnorePointer(
              child: ColoredBox(
                color: canvas.withValues(
                  alpha: (1 - animation.value).clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
        Scaffold(
          key: const ValueKey('settings-detail-route-scaffold'),
          backgroundColor: Colors.transparent,
          body: child,
        ),
      ],
    );
  }
}
