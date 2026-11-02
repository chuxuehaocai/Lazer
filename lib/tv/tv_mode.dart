import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../animation/apple_spring.dart';
import '../state/build_safe_notifier.dart';
import '../theme/apple_design.dart';

/// Native bridge for Android TV recognition.
///
/// The manifest marks the app `LEANBACK_LAUNCHER`-capable, but Flutter still
/// needs to know whether the device it runs on is actually a television: a TV
/// has no touch screen and is driven by a D-pad remote, so every tappable
/// surface also has to be reachable with directional focus.
const MethodChannel _tvChannel = MethodChannel('dev.naominet.lazer/tv');

/// Whether the Android device under this app is a television.
///
/// Only Android can answer; every other platform keeps its existing input
/// model. A missing plugin (tests, hot-restart before the activity is wired)
/// is not an error — it simply means "not a TV".
Future<bool> detectTelevision() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    final bool? result = await _tvChannel
        .invokeMethod<bool>('isTelevision')
        .timeout(const Duration(milliseconds: 800));
    return result ?? false;
  } catch (_) {
    return false;
  }
}

/// Ordinary Android configuration and hardware features; no Wear OS APIs.
Future<({bool watch, bool round})> detectWatch() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return (watch: false, round: false);
  }
  try {
    final result = await _tvChannel
        .invokeMapMethod<String, bool>('watchShape')
        .timeout(const Duration(milliseconds: 800));
    return (watch: result?['watch'] ?? false, round: result?['round'] ?? false);
  } catch (_) {
    return (watch: false, round: false);
  }
}

/// Publishes whether the television interaction model is active.
///
/// This is separate from the density profile: a user can force the television
/// surface on a touch device for testing, and a TV can be told to use the
/// standard density without losing remote navigation.
class TvScope extends InheritedWidget {
  const TvScope({super.key, required this.active, required super.child});

  /// Whether tappable surfaces must also be focusable with a remote.
  final bool active;

  static bool isActive(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvScope>()?.active ?? false;

  @override
  bool updateShouldNotify(TvScope oldWidget) => oldWidget.active != active;
}

/// Extra breathing room a television needs so overscan does not clip chrome.
///
/// Android TV reports no safe-area padding of its own, yet many panels crop a
/// few percent off every edge. The shell and the immersive player both inset
/// their content with this instead of relying on [SafeArea] alone.
EdgeInsets tvSafeInsets(BuildContext context) => TvScope.isActive(context)
    ? const EdgeInsets.fromLTRB(24, 16, 24, 16)
    : EdgeInsets.zero;

/// Focuses [node] and scrolls its ancestors just enough to show it.
///
/// Flutter's default traversal callback aligns the target to the edge of the
/// viewport every time, so a row that is already visible still jumps. A remote
/// moves constantly; the television wants minimal, animated scrolling instead.
/// [RenderObject.showOnScreen] walks every ancestor scroll viewport (the page
/// and the horizontal shelf around a card) and reveals both axes only when the
/// control is actually outside them.
void revealTvFocus(
  FocusNode node, {
  Duration duration = const Duration(milliseconds: 160),
  Curve curve = const AppleSpringCurve(),
}) {
  final BuildContext? target = node.context;
  node.requestFocus();
  if (target == null) return;
  target.findRenderObject()?.showOnScreen(
    duration: MediaQuery.disableAnimationsOf(target) ? Duration.zero : duration,
    curve: curve,
  );
}

/// Whether the ten-foot presentation is in effect.
///
/// The large-screen mode owns both the layout and the input model: it replaces
/// the source-list shell with the shelf-and-rail composition, and it is exactly
/// the case where a remote must be able to reach everything. Off a large
/// screen this is false and every helper in this file collapses to its child.
bool largeScreenModeOf(BuildContext context) => TvScope.isActive(context);

/// The D-pad traversal used by the large-screen presentation.
///
/// Flutter's reading-order policy walks the widget tree, so on a grid of cards
/// "down" can jump sideways along whatever the build order happens to be. This
/// policy follows the geometry instead: left/right stay inside a shelf,
/// up/down land on the item physically above or below, and reversing direction
/// retraces the path that was just taken. Focus is revealed with
/// [revealTvFocus], which scrolls only when the target is actually outside its
/// viewports.
///
/// Lazily built lists only create the children near the viewport, so a move at
/// the edge has no node to land on. Rather than dead-ending there, the nearest
/// scroll view on the matching axis is nudged in that direction: the classic
/// "bump to scroll" behaviour of a television. The next press continues from
/// the items that were just revealed.
class LargeScreenTraversalPolicy extends ReadingOrderTraversalPolicy {
  LargeScreenTraversalPolicy()
    : super(requestFocusCallback: _requestFocusWithReveal);

  static void _requestFocusWithReveal(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) => revealTvFocus(
    node,
    duration: duration ?? const Duration(milliseconds: 160),
    curve: curve ?? const AppleSpringCurve(),
  );

  /// Tab (and any helper that walks the order) becomes a vertical step, which
  /// is the only meaningful order on a shelf-and-rail screen.
  @override
  bool next(FocusNode currentNode) =>
      inDirection(currentNode, TraversalDirection.down);

  @override
  bool previous(FocusNode currentNode) =>
      inDirection(currentNode, TraversalDirection.up);

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final bool moved = super.inDirection(currentNode, direction);
    if (!moved) _scrollToward(currentNode, direction);
    return moved;
  }

  /// Scrolls the nearest matching scroll view by most of a viewport.
  ///
  /// A vertical press never scrolls a horizontal shelf, and a horizontal press
  /// never scrolls the page: the axis has to agree with the direction the
  /// viewer asked for. At the end of the scroll the call is a no-op, so the
  /// D-pad simply stops instead of overshooting.
  void _scrollToward(FocusNode node, TraversalDirection direction) {
    final BuildContext? context = node.context;
    if (context == null || !context.mounted) return;
    final Axis wanted =
        direction == TraversalDirection.up ||
            direction == TraversalDirection.down
        ? Axis.vertical
        : Axis.horizontal;
    ScrollableState? scrollable;
    context.visitAncestorElements((Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final ScrollableState candidate = element.state as ScrollableState;
        if (axisDirectionToAxis(candidate.axisDirection) == wanted) {
          scrollable = candidate;
          return false;
        }
      }
      return true;
    });
    final ScrollableState? target = scrollable;
    if (target == null) return;
    final ScrollPosition position = target.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final bool forward =
        direction == TraversalDirection.down ||
        direction == TraversalDirection.right;
    final bool reversed =
        target.axisDirection == AxisDirection.up ||
        target.axisDirection == AxisDirection.left;
    final double step = position.viewportDimension * .62;
    final double next =
        (position.pixels + (forward ? step : -step) * (reversed ? -1 : 1))
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((next - position.pixels).abs() < 1) return;
    unawaited(
      position.animateTo(
        next,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppleSpring.responsive.duration,
        curve: const AppleSpringCurve(),
      ),
    );
  }
}

/// Installs the large-screen traversal policy for remote navigation.
///
/// Off a large screen the child is returned untouched, so desktop and phone
/// keep Flutter's own traversal.
class TvTraversalScope extends StatelessWidget {
  const TvTraversalScope({super.key, required this.child});

  final Widget child;

  static final FocusTraversalPolicy _policy = LargeScreenTraversalPolicy();

  @override
  Widget build(BuildContext context) => TvScope.isActive(context)
      ? FocusTraversalGroup(policy: _policy, child: child)
      : child;
}

/// Registry of player panels drawn through [OverlayPortal].
///
/// Overlay entries are siblings of the route, so a remote Back press never
/// reaches them: the system pop would leave the app (or navigate the shell)
/// while the queue card stayed on screen. Panels register a closer here, and
/// the shell consumes Back with [closeTop] before its own navigation.
class TvOverlayStack extends ChangeNotifier with BuildSafeNotifier {
  TvOverlayStack._();

  static final TvOverlayStack instance = TvOverlayStack._();

  final List<VoidCallback> _closers = <VoidCallback>[];

  bool get hasOpen => _closers.isNotEmpty;

  void push(VoidCallback close) {
    _closers.add(close);
    notifyListeners();
  }

  void remove(VoidCallback close) {
    if (_closers.remove(close)) notifyListeners();
  }

  /// Closes the most recently opened panel; false when nothing is open.
  bool closeTop() {
    if (_closers.isEmpty) return false;
    final VoidCallback close = _closers.removeLast();
    notifyListeners();
    close();
    return true;
  }
}

/// A tap target that also participates in D-pad focus traversal.
///
/// The shell draws every card, row and transport glyph with a
/// [GestureDetector], which a remote can never reach. On a television this
/// widget adds the missing half: a focus node in the directional traversal
/// order, ActivateIntent handling (the Select/Enter key), and a high-contrast
/// ring at ten-foot distance. Off a TV it returns [child] untouched, so the
/// pointer, hover and semantics behaviour of the existing widgets is unchanged.
class TvTapTarget extends StatefulWidget {
  const TvTapTarget({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.onFocusChange,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.focusScale = 1.02,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Lets a card treat remote focus like hover (raise its play badge, lift the
  /// artwork) without duplicating a second focus listener.
  final ValueChanged<bool>? onFocusChange;

  /// Shape of the focus ring; match the card's own corner radius.
  final BorderRadius borderRadius;

  /// A slight lift makes the focused card read as selected from across a room.
  final double focusScale;

  @override
  State<TvTapTarget> createState() => _TvTapTargetState();
}

class _TvTapTargetState extends State<TvTapTarget>
    with SingleTickerProviderStateMixin {
  bool _focused = false;
  bool _reduceMotion = false;
  late final AnimationController _focus = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );

  @override
  void initState() {
    super.initState();
    _focus;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion || !TvScope.isActive(context)) {
      _focus.value = _focused ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
    _focus.springTo(
      value ? 1 : 0,
      spring: AppleSpring.responsive,
      reduceMotion: _reduceMotion,
    );
    widget.onFocusChange?.call(value);
  }

  void _activate() {
    if (!widget.enabled) return;
    widget.onTap?.call();
  }

  @override
  void didUpdateWidget(covariant TvTapTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _focused) _setFocused(false);
  }

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.enabled && widget.onTap != null;
    if (!TvScope.isActive(context) || !interactive) return widget.child;
    return FocusableActionDetector(
      enabled: true,
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      onFocusChange: _setFocused,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            _activate();
            return null;
          },
        ),
      },
      child: AnimatedBuilder(
        animation: _focus,
        builder: (context, child) => Transform.scale(
          scale: 1 + (widget.focusScale - 1) * _focus.value,
          transformHitTests: false,
          child: child,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            widget.child,
            if (_focused)
              Positioned.fill(
                child: IgnorePointer(
                  child: TvFocusOutline(borderRadius: widget.borderRadius),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The white ring + black halo used for remote focus everywhere.
///
/// White alone disappears over light artwork and black alone disappears over
/// the dark player, so the two are drawn together: the black halo outlines the
/// ring on white, and the white ring stays crisp on black. Both are strokes —
/// a filled shadow would darken the whole card through the transparent middle
/// of its decoration.
class TvFocusOutline extends StatelessWidget {
  const TvFocusOutline({
    super.key,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.width = 3,
  });

  final BorderRadius borderRadius;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _TvFocusRingPainter(borderRadius: borderRadius, width: width),
  );
}

class _TvFocusRingPainter extends CustomPainter {
  const _TvFocusRingPainter({required this.borderRadius, required this.width});

  final BorderRadius borderRadius;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Keep the whole stroke inside the card: half of a centred stroke would be
    // clipped by the focus target's bounds.
    final double inset = width / 2 + 2;
    final RRect ring = borderRadius.toRRect(Offset.zero & size).deflate(inset);
    final Paint halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width + 4
      ..color = const Color(0xB3000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = Colors.white;
    canvas.drawRRect(ring, halo);
    canvas.drawRRect(ring, stroke);
  }

  @override
  bool shouldRepaint(_TvFocusRingPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius || oldDelegate.width != width;
}

/// Draws a TV selection wash and ring around a group of Material controls.
///
/// Material's own focus overlay is a faint tint that disappears at ten feet,
/// and a dropdown or switch owns its focus node, so a [TvTapTarget] cannot be
/// placed around it without stealing the key handling. This wrapper watches
/// focus in its subtree without becoming a focus stop itself: the control
/// keeps its own Select/arrow behaviour while the whole row shows where the
/// remote is.
class TvFocusHighlight extends StatefulWidget {
  const TvFocusHighlight({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  State<TvFocusHighlight> createState() => _TvFocusHighlightState();
}

class _TvFocusHighlightState extends State<TvFocusHighlight> {
  final FocusNode _watcher = FocusNode(
    debugLabel: 'tv-focus-highlight',
    canRequestFocus: false,
    skipTraversal: true,
  );
  bool _focused = false;

  @override
  void dispose() {
    _watcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!TvScope.isActive(context)) return widget.child;
    return Focus(
      focusNode: _watcher,
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool value) {
        if (mounted && value != _focused) setState(() => _focused = value);
      },
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppleSpring.responsive.duration,
        curve: const AppleSpringCurve(),
        decoration: BoxDecoration(
          color: _focused
              ? AppleSemanticColors.of(context).fill
              : Colors.transparent,
          borderRadius: widget.borderRadius,
        ),
        child: Stack(
          children: <Widget>[
            widget.child,
            if (_focused)
              Positioned.fill(
                child: IgnorePointer(
                  child: TvFocusOutline(borderRadius: widget.borderRadius),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Moves remote focus into a page when it appears or returns to the front.
///
/// A remote starts with no pointer and therefore no focus: without an anchor
/// the first D-pad press does nothing. Each page owns one of these regions;
/// when its [focusToken] changes (a new section, a closed player) the first
/// actionable descendant receives focus. The region is a plain [Focus] node,
/// not a [FocusScope], so traversal can still leave the content for the rail
/// and the transport bar.
class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({super.key, required this.child, this.focusToken});

  final Widget child;

  /// Changing this value re-acquires focus for the region's first control.
  final Object? focusToken;

  @override
  State<TvFocusRegion> createState() => _TvFocusRegionState();
}

class _TvFocusRegionState extends State<TvFocusRegion> {
  final FocusNode _region = FocusNode(
    debugLabel: 'tv-focus-region',
    canRequestFocus: false,
    skipTraversal: true,
  );
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Dependencies change on the first frame as well as when the theme or the
    // large-screen scope updates. Only fill an empty focus here: revealing the
    // first control through showOnScreen would scroll a freshly opened page
    // away from its top.
    if (TvScope.isActive(context)) _scheduleInitial();
  }

  @override
  void didUpdateWidget(covariant TvFocusRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusToken != widget.focusToken) _schedule();
  }

  @override
  void dispose() {
    _region.dispose();
    super.dispose();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !TvScope.isActive(context)) return;
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      // Focus already lives in this page (for example after a rebuild): don't
      // yank it back to the top.
      if (primary != null && _isInside(primary)) return;
      final FocusNode? first = _firstControl();
      if (first != null) revealTvFocus(first);
    });
  }

  /// Claims focus when a page has just produced its first control.
  ///
  /// A page often starts on a loading notice with nothing focusable and only
  /// swaps in its content when the network answers. That swap does not change
  /// [TvFocusRegion.focusToken], so without this retry a television would sit
  /// at the root with no focused control and the first D-pad press would land
  /// on whatever happens to be first in the reading order. Only an empty
  /// primary focus is filled: once the user has moved somewhere, rebuilds
  /// never pull focus back.
  void _scheduleInitial() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !TvScope.isActive(context)) return;
      // An empty route scope is the primary focus on every new page even
      // though nothing is focused inside it. Only a real control counts as
      // already anchored.
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      if (primary != null && primary is! FocusScopeNode) return;
      final FocusNode? first = _firstControl();
      // The opening anchor must not scroll: a page that starts with the top
      // shelf above the viewport looks like it opened halfway down. Later
      // anchors (a closed player, a new section) still reveal their target.
      if (first != null) first.requestFocus();
    });
  }

  FocusNode? _firstControl() => _region.traversalDescendants
      .where((FocusNode node) => node.context != null && node.canRequestFocus)
      .firstOrNull;

  bool _isInside(FocusNode node) {
    for (FocusNode? current = node; current != null; current = current.parent) {
      if (current == _region) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!TvScope.isActive(context)) return widget.child;
    _scheduleInitial();
    return Focus(
      focusNode: _region,
      canRequestFocus: false,
      skipTraversal: true,
      child: widget.child,
    );
  }
}
