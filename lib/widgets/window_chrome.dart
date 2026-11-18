import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import '../animation/apple_spring.dart';
import '../state/build_safe_notifier.dart';
import '../theme/app_palette.dart';
import '../tv/tv_mode.dart';
import 'window_chrome_surface.dart';

export 'window_chrome_surface.dart';

/// Connects the active player's controls to the window chrome outside its
/// navigator. The most recently attached presentation owns the chrome.
class WindowChromeController extends ValueNotifier<bool>
    with BuildSafeNotifier {
  WindowChromeController({TickerProvider? vsync}) : super(true) {
    final TickerProvider? provider = vsync;
    if (provider != null) {
      _handover = AnimationController(
        vsync: provider,
        value: 1,
        duration: _handoverSpan,
        debugLabel: 'window-chrome-handover',
      )..addStatusListener(_handoverStatus);
    }
  }

  /// How long the set that is leaving keeps the capsule's extension.
  static const int _handoverOutMs = 160;

  /// How long the incoming set takes to arrive once the extension is free.
  static const int _handoverInMs = 260;

  /// The outgoing half of a capsule handover: a page command on its way out.
  static const Duration handoverOut = Duration(milliseconds: _handoverOutMs);

  /// The incoming half of a capsule handover: the set taking over.
  static const Duration handoverIn = Duration(milliseconds: _handoverInMs);

  /// One whole handover, exit and entrance included.
  static const Duration _handoverSpan = Duration(
    milliseconds: _handoverOutMs + _handoverInMs,
  );

  /// Share of the handover that belongs to the outgoing set.
  static const double _outShare =
      _handoverOutMs / (_handoverOutMs + _handoverInMs);

  final List<_WindowChromeSource> _sources = [];
  final List<_ChromeActionSet> _actions = [];

  /// Hands the capsule's extension from one action set to the next. Null in a
  /// pure unit test with no ticker provider: handovers then land at once.
  AnimationController? _handover;

  /// The action set that owns the extension right now.
  Object? _owner;

  /// The set that is walking out of the extension ahead of [_owner].
  Object? _retiring;

  /// Presence the retiring set had when the handover started, so an interrupted
  /// exit continues from where it was instead of jumping back to full.
  double _retiringPresence = 1;

  /// Presence the incoming set already had when the handover started. Zero for
  /// a fresh handover, non-zero only when a running one is reversed.
  double _arrivingFrom = 0;

  bool _reduceMotion = false;
  bool _ownerSyncScheduled = false;
  bool _disposed = false;

  /// How far the chrome's own unfold has travelled, reported by the frame.
  ///
  /// A handover only plays while the extension is actually on screen: when the
  /// capsule is folding shut anyway (the player being dismissed), the collapse
  /// already carries the outgoing set away and a second, invisible handover
  /// would only delay the page command that is coming back.
  double _revealed = 1;

  static const AppleSpringCurve _ease = AppleSpringCurve();

  bool get playerPresented => _sources.isNotEmpty;

  /// The action set that currently owns the capsule's extension.
  Object? get actionOwner => _owner;

  /// Ticks while the extension travels between two action sets. Every widget
  /// that paints [presenceOf] has to listen to it.
  Listenable? get handover => _handover;

  /// Lands handovers at once when the platform asks for less motion.
  void syncReduceMotion(bool value) {
    if (_reduceMotion == value) return;
    _reduceMotion = value;
    if (!value) return;
    _retiring = null;
    _settleHandover();
    notifyListeners();
  }

  /// Reports how far the capsule's unfold has travelled, without notifying.
  void syncRevealed(double progress) {
    if (!progress.isFinite) return;
    _revealed = progress.clamp(0.0, 1.0);
  }

  /// How much of the capsule's extension [owner] may paint right now.
  ///
  /// 1 for the set that owns it, 0 for every other set. A handover runs in two
  /// halves: the outgoing set leaves over [handoverOut], and only once it is
  /// gone does the incoming set arrive over [handoverIn]. A page command and a
  /// presented player's buttons therefore never paint over each other.
  double presenceOf(Object owner) {
    final bool mine = identical(owner, _owner);
    if (!mine && !identical(owner, _retiring)) return 0;
    if (_reduceMotion) return mine ? 1 : 0;
    final AnimationController? handover = _handover;
    if (handover == null) return mine ? 1 : 0;
    final double elapsed = handover.value;
    if (!mine) {
      // A set leaving the capsule holds its place and then accelerates away:
      // the mirror of the arriving curve, so the exit reads as an exit.
      final double leave = (elapsed / _outShare).clamp(0.0, 1.0);
      return (_retiringPresence * _ease.transform(1 - leave)).clamp(0.0, 1.0);
    }
    if (_retiring == null) return 1;
    final double arrive = ((elapsed - _outShare) / (1 - _outShare)).clamp(
      0.0,
      1.0,
    );
    return (_arrivingFrom + (1 - _arrivingFrom) * _ease.transform(arrive))
        .clamp(0.0, 1.0);
  }

  /// The action set that owns the capsule's extension. A player's song actions
  /// always outrank a page's own actions, so opening the player never loses its
  /// buttons to a settings page that is still mounted underneath.
  _ChromeActionSet? get _activeActions {
    // Snapshot: a sibling page can register or drop its set from inside its own
    // build, and iterating the live list would then throw while another widget
    // is asking for its geometry.
    for (final entry in List<_ChromeActionSet>.of(_actions).reversed) {
      if (entry.playerDriven) return entry;
    }
    return _actions.lastOrNull;
  }

  bool _hasActions(Object owner) =>
      _actions.any((entry) => identical(entry.owner, owner));

  _ChromeActionSet? _actionsOf(Object owner) {
    for (final entry in _actions) {
      if (identical(entry.owner, owner)) return entry;
    }
    return null;
  }

  void _handoverStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _retiring = null;
  }

  /// Moves the extension to whichever set won it, staging the exit of the set
  /// that has to give it up.
  ///
  /// Everything that touches [_handover] runs from here rather than from the
  /// caller: sets register and retire from inside their own build, and the two
  /// of them paint from the root overlay, so marking either dirty there would
  /// ask Flutter to rebuild a subtree it is not currently building.
  void _syncOwner() {
    if (_disposed) return;
    final Object? retiring = _retiring;
    if (retiring != null && !_hasActions(retiring)) {
      // The set that was walking out has left the tree: there is no exit left
      // to play, so the incoming set takes the extension straight away.
      _retiring = null;
      _settleHandover();
      notifyListeners();
    }
    final Object? next = _activeActions?.owner;
    if (identical(next, _owner)) return;
    final Object? previous = _owner;
    final double carried = previous == null ? 0 : presenceOf(previous);
    final double arriving = next == null ? 0 : presenceOf(next);
    // A set that is already sliding out (its route stopped being current, or
    // the player it speaks for was dismissed) has nothing left to give up.
    final bool previousPaints =
        previous != null && (_actionsOf(previous)?.active ?? false);
    _owner = next;
    if (next == null) {
      // Nothing claims the extension: it folds away with the chrome's own
      // spring, so the set that just gave it up simply stops painting.
      _retiring = null;
      _settleHandover();
      notifyListeners();
      return;
    }
    final AnimationController? handover = _handover;
    final bool handOff =
        previous != null &&
        carried > 0 &&
        previousPaints &&
        _hasActions(previous) &&
        handover != null &&
        _revealed * carried > .04;
    if (!handOff) {
      _retiring = null;
      _settleHandover();
      notifyListeners();
      return;
    }
    _retiring = previous;
    _retiringPresence = carried;
    _arrivingFrom = arriving;
    handover
      ..stop()
      ..value = 0
      ..animateTo(1, duration: MotionTiming.scale(_handoverSpan));
    notifyListeners();
  }

  void _settleHandover() {
    final AnimationController? handover = _handover;
    if (handover == null || handover.value == 1) return;
    handover
      ..stop()
      ..value = 1;
  }

  /// Runs [_syncOwner] once the frame is no longer building.
  void _scheduleOwnerSync() {
    if (_disposed) return;
    SchedulerPhase phase;
    try {
      phase = SchedulerBinding.instance.schedulerPhase;
    } catch (_) {
      // No binding (pure unit tests): resolve right away.
      _syncOwner();
      return;
    }
    if (phase != SchedulerPhase.persistentCallbacks &&
        phase != SchedulerPhase.midFrameMicrotasks) {
      _syncOwner();
      return;
    }
    if (_ownerSyncScheduled) return;
    _ownerSyncScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _ownerSyncScheduled = false;
      _syncOwner();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  double get actionsWidth => _activeActions?.width ?? 0;
  bool get actionsActive => _activeActions?.active ?? false;

  /// How wide the capsule's extension needs to be painted right now.
  ///
  /// While two sets are on the capsule the surface keeps the wider of the two,
  /// so the pill never pinches between the command that is leaving and the
  /// buttons that are arriving.
  double get paintedActionsWidth {
    double extent = 0;
    for (final entry in List<_ChromeActionSet>.of(_actions)) {
      final bool onCapsule =
          identical(entry.owner, _owner) || identical(entry.owner, _retiring);
      if (!onCapsule) continue;
      extent = math.max(extent, entry.width);
    }
    return extent;
  }

  /// Whether the winning action set wants the capsule extended. A page's
  /// commands show while their route is current; a player's only while it is
  /// actually presented, so a cached player page never props the capsule open.
  bool get actionsExpanded {
    final _ChromeActionSet? set = _activeActions;
    if (set == null || !set.active) return false;
    return !set.playerDriven || playerPresented;
  }

  /// Registers only geometry, keeping the actual buttons in their page's
  /// overlay portal so they retain their theme, route and action context.
  void updateActions(
    Object owner, {
    required double width,
    required bool active,
    bool playerDriven = true,
  }) {
    if (_disposed) return;
    final double oldWidth = actionsWidth;
    final bool oldActive = actionsActive;
    final Object? oldOwner = _owner;
    final index = _actions.indexWhere((entry) => identical(entry.owner, owner));
    final entry = (
      owner: owner,
      width: width,
      active: active,
      playerDriven: playerDriven,
    );
    if (index < 0) {
      _actions.add(entry);
    } else if (index < _actions.length) {
      _actions[index] = entry;
    } else {
      _actions.add(entry);
    }
    _scheduleOwnerSync();
    if (oldWidth != actionsWidth ||
        oldActive != actionsActive ||
        !identical(oldOwner, _owner)) {
      notifyListeners();
    }
  }

  void removeActions(Object owner) {
    if (_disposed) return;
    final double oldWidth = actionsWidth;
    final bool oldActive = actionsActive;
    final Object? oldOwner = _owner;
    _actions.removeWhere((entry) => identical(entry.owner, owner));
    _scheduleOwnerSync();
    if (oldWidth != actionsWidth ||
        oldActive != actionsActive ||
        !identical(oldOwner, _owner)) {
      notifyListeners();
    }
  }

  void attach(
    ValueListenable<bool> source, {
    VoidCallback? onActivity,
    ValueChanged<int>? onPointerStart,
    ValueChanged<int>? onPointerEnd,
    VoidCallback? onPointerRelease,
  }) {
    if (_disposed) return;
    final bool wasPresented = playerPresented;
    _removeSource(source);
    final binding = _WindowChromeSource(
      source: source,
      onActivity: onActivity,
      onPointerStart: onPointerStart,
      onPointerEnd: onPointerEnd,
      onPointerRelease: onPointerRelease,
      onChanged: _sync,
    );
    _sources.add(binding);
    source.addListener(binding.onChanged);
    _sync(presentationChanged: wasPresented != playerPresented);
  }

  void detach(ValueListenable<bool> source) {
    if (_disposed) return;
    final bool wasPresented = playerPresented;
    _removeSource(source);
    _sync(presentationChanged: wasPresented != playerPresented);
  }

  void _removeSource(ValueListenable<bool> source) {
    final index = _sources.indexWhere(
      (binding) => identical(binding.source, source),
    );
    if (index < 0) return;
    final binding = _sources.removeAt(index);
    binding.source.removeListener(binding.onChanged);
  }

  void _sync({bool presentationChanged = false}) {
    if (_disposed) return;
    final bool next = _sources.isEmpty ? true : _sources.last.source.value;
    if (value != next) {
      value = next;
    } else if (presentationChanged) {
      notifyListeners();
    }
  }

  void pointerDown(int pointer) {
    if (_disposed || _sources.isEmpty) return;
    final active = _sources.last;
    active.onPointerStart?.call(pointer);
    active.onActivity?.call();
  }

  void pointerUp(int pointer) {
    if (_disposed || _sources.isEmpty) return;
    _sources.last.onPointerEnd?.call(pointer);
  }

  /// Drops the pointer holds the presented player is still tracking.
  ///
  /// A window drag runs inside the platform's own modal move loop, which owns
  /// the pointer until the button is released. The view therefore never
  /// receives the matching pointer-up, and a player that holds its controls
  /// awake for the duration of a press would stay awake until the next click.
  /// Every window drag calls this as soon as its move loop returns.
  void releasePointers() {
    if (_disposed || _sources.isEmpty) return;
    _sources.last.onPointerRelease?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final binding in _sources) {
      binding.source.removeListener(binding.onChanged);
    }
    _sources.clear();
    _actions.clear();
    _handover?.removeStatusListener(_handoverStatus);
    _handover?.dispose();
    _handover = null;
    super.dispose();
  }
}

class _WindowChromeSource {
  const _WindowChromeSource({
    required this.source,
    required this.onActivity,
    required this.onPointerStart,
    required this.onPointerEnd,
    required this.onPointerRelease,
    required this.onChanged,
  });

  final ValueListenable<bool> source;
  final VoidCallback? onActivity;
  final ValueChanged<int>? onPointerStart, onPointerEnd;

  /// Retires holds whose release never reached the view, such as the press
  /// that a window drag handed to the platform's move loop.
  final VoidCallback? onPointerRelease;
  final VoidCallback onChanged;
}

/// One page's claim on the capsule's extension: how wide it needs to be and
/// whether its route is still the current one.
///
/// A record rather than a class on purpose: this list exists across hot
/// reloads, and changing a field's element type is exactly what the VM cannot
/// patch — the running list keeps its old element type and the first insertion
/// throws a `TypeError`. Record fields also make the value immutable, which is
/// all this bookkeeping needs.
typedef _ChromeActionSet = ({
  Object owner,
  double width,
  bool active,
  bool playerDriven,
});

class WindowChromeScope extends InheritedWidget {
  const WindowChromeScope({
    super.key,
    required this.controller,
    this.inline = false,
    this.reveal,
    this.chromeTheme,
    required super.child,
  });

  final WindowChromeController controller;
  final bool inline;
  final Animation<double>? reveal;
  final ThemeData? chromeTheme;

  static WindowChromeScope? maybeLayoutOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowChromeScope>();

  static WindowChromeController? maybeOf(BuildContext context) =>
      maybeLayoutOf(context)?.controller;

  @override
  bool updateShouldNotify(WindowChromeScope oldWidget) =>
      controller != oldWidget.controller ||
      inline != oldWidget.inline ||
      reveal != oldWidget.reveal ||
      chromeTheme != oldWidget.chromeTheme;
}

/// Reserves the floating capsule's band while its actions use the root overlay.
/// The frame no longer pushes pages down with MediaQuery padding, so the band
/// height comes from the capsule geometry itself.
class WindowChromeHeader extends StatelessWidget {
  const WindowChromeHeader({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final layout = WindowChromeScope.maybeLayoutOf(context);
    if (layout?.inline != true) return child;
    return Padding(
      padding: const EdgeInsets.only(top: kInlineChromeInset),
      child: child,
    );
  }
}

/// Gives a page's own header back the title-bar behaviour: drag it to move the
/// window, double-click it to maximize.
///
/// Inline chrome floats, so the top of the window belongs to the page; covering
/// that area with an invisible drag layer would swallow clicks on whatever the
/// page puts there. Instead the header that already reads as a title bar becomes
/// the handle. Inert in classic mode (the frame owns a real strip), off desktop
/// and on a television, where minimizing and maximizing make no sense.
class WindowDragArea extends StatefulWidget {
  const WindowDragArea({super.key, required this.child, this.bandHeight});

  final Widget child;

  /// When set, only presses that start inside this many pixels from the top
  /// count as a window drag. Wrapping a whole page keeps the title-bar band
  /// draggable while everything below it still belongs to the page.
  final double? bandHeight;

  @override
  State<WindowDragArea> createState() => _WindowDragAreaState();
}

class _WindowDragAreaState extends State<WindowDragArea> {
  /// How far the pointer has to travel before the press becomes a window drag.
  /// Small enough to feel immediate, large enough that a click on a button
  /// inside the header never turns into one.
  static const double _slop = 5;

  /// A second press this close in time and space toggles maximize, matching the
  /// double-click every desktop title bar answers to.
  static const Duration _doubleClick = Duration(milliseconds: 380);
  static const double _doubleClickSlop = 6;

  Offset? _origin;
  bool _dragging = false;
  Offset? _lastPressAt;
  Duration? _lastPressTime;

  void _pressed(PointerDownEvent event) {
    // Secondary buttons open context menus, they do not move windows.
    if (event.buttons != kPrimaryButton) return;
    final double? band = widget.bandHeight;
    if (band != null && event.localPosition.dy > band) return;
    final Offset? previousAt = _lastPressAt;
    final Duration? previousTime = _lastPressTime;
    final bool mouse =
        event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.stylus;
    if (mouse &&
        previousAt != null &&
        previousTime != null &&
        event.timeStamp - previousTime <= _doubleClick &&
        (event.position - previousAt).distance <= _doubleClickSlop) {
      _lastPressAt = null;
      _lastPressTime = null;
      unawaited(_toggleMaximize());
      return;
    }
    _lastPressAt = event.position;
    _lastPressTime = event.timeStamp;
    _origin = event.position;
    _dragging = false;
  }

  void _moved(PointerMoveEvent event) {
    final Offset? origin = _origin;
    if (origin == null || _dragging) return;
    if ((event.position - origin).distance < _slop) return;
    _dragging = true;
    // Fire and forget: the platform side blocks inside the OS move loop until
    // the button is released, so awaiting it would stall this handler.
    //
    // The move loop also consumes that release: the view never sees the
    // pointer-up of the press that started the drag. Retire the hold once the
    // loop returns, or a presented player keeps its controls awake until the
    // next click.
    final WindowChromeController? chrome = WindowChromeScope.maybeOf(context);
    unawaited(
      windowManager.startDragging().then<void>((_) {
        chrome?.releasePointers();
      }, onError: (Object _) {}),
    );
  }

  void _released(PointerEvent event) {
    _origin = null;
    _dragging = false;
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {
      // No window channel (tests, headless): the press is simply a press.
    }
  }

  @override
  Widget build(BuildContext context) {
    final WindowChromeScope? layout = WindowChromeScope.maybeLayoutOf(context);
    if (layout?.inline != true || TvScope.isActive(context)) {
      return widget.child;
    }
    // A [Listener] rather than a pan recognizer: a page header lives inside the
    // page's own scroll view, and a scroll view's vertical drag recognizer wins
    // the gesture arena against a competing pan — the page would scroll instead
    // of the window moving. Pointer events are read directly instead, so the
    // header moves the window while buttons inside it keep their own taps.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pressed,
      onPointerMove: _moved,
      onPointerUp: _released,
      onPointerCancel: _released,
      child: widget.child,
    );
  }
}

/// A thin, invisible band that behaves like a title bar.
///
/// Pages that do not open with a large title — the home feed, for example — still
/// need somewhere to grab the window. The band collapses to nothing wherever
/// [WindowDragArea] is inert, so it never leaves a gap on a phone or a television.
class WindowDragBand extends StatelessWidget {
  const WindowDragBand({super.key, this.height = 14});

  final double height;

  @override
  Widget build(BuildContext context) {
    final WindowChromeScope? layout = WindowChromeScope.maybeLayoutOf(context);
    if (layout?.inline != true || TvScope.isActive(context)) {
      return const SizedBox.shrink();
    }
    return WindowDragArea(
      child: SizedBox(height: height, width: double.infinity),
    );
  }
}

/// Song actions occupy the extending left half of the window capsule. The
/// surface is painted once by WindowTitleArea; this portal paints only buttons.
class WindowChromeActions extends StatefulWidget {
  const WindowChromeActions({
    super.key,
    required this.children,
    this.leading,
    this.leadingWidth = kWindowChromeTextActionWidth,
    this.playerDriven = true,
  });

  final List<Widget> children;

  /// A text command that opens the row, separated from the icon cluster by a
  /// hairline. Pages that own one command ("恢复默认") hand it here instead of
  /// leaving it in the page header, where the capsule would paint over it.
  final Widget? leading;

  final double leadingWidth;

  /// Whether this set speaks for a presented player (song actions) or for a
  /// page. The player's set always wins while both are mounted.
  final bool playerDriven;

  @override
  State<WindowChromeActions> createState() => _WindowChromeActionsState();
}

class _WindowChromeActionsState extends State<WindowChromeActions> {
  late final _portal = OverlayPortalController()..show();
  WindowChromeController? _chrome;

  double get _width =>
      kWindowChromeButtonWidth * widget.children.length +
      (widget.leading == null
          ? 0
          : widget.leadingWidth + kWindowChromeActionDivider);

  void _register(WindowChromeController? chrome, double width, bool active) {
    if (_chrome != chrome) {
      _chrome?.removeActions(this);
      _chrome = chrome;
    }
    _chrome?.updateActions(
      this,
      width: width,
      active: active,
      playerDriven: widget.playerDriven,
    );
  }

  @override
  void dispose() {
    _chrome?.removeActions(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = WindowChromeScope.maybeLayoutOf(context);
    final reveal = layout?.reveal;
    final double width = _width;
    if (layout?.inline != true || reveal == null || TvScope.isActive(context)) {
      _register(null, 0, false);
      return DecoratedBox(
        key: const ValueKey('desktop-player-actions'),
        decoration: BoxDecoration(
          color: context.colors.onPlayer.withValues(alpha: .045),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: context.colors.onPlayer.withValues(alpha: .18),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const _WindowChromeActionDivider(),
              ],
              for (var i = 0; i < widget.children.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                widget.children[i],
              ],
            ],
          ),
        ),
      );
    }
    final bool routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _register(layout!.controller, width, routeCurrent);
    final WindowChromeController chrome = layout.controller;
    // Repaints for the capsule's own unfold, for a handover's frames, and
    // whenever the set that owns the extension changes.
    final Listenable signals = Listenable.merge(<Listenable?>[
      reveal,
      chrome.handover,
      chrome,
    ]);
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) => Positioned(
        top: kWindowChromeTop,
        right: kWindowChromeEnd + kWindowChromeButtonWidth * 3,
        child: Offstage(
          offstage: !routeCurrent,
          child: Theme(
            data: layout.chromeTheme ?? Theme.of(context),
            child: Listener(
              onPointerDown: (event) =>
                  layout.controller.pointerDown(event.pointer),
              onPointerUp: (event) =>
                  layout.controller.pointerUp(event.pointer),
              onPointerCancel: (event) =>
                  layout.controller.pointerUp(event.pointer),
              child: AnimatedBuilder(
                animation: signals,
                builder: (context, _) {
                  // A set that does not own the extension paints nothing: the
                  // previous owner walks out first and the next one only then
                  // arrives, so two sets never share this slot.
                  final double presence = chrome.presenceOf(this);
                  final double progress = (1 - reveal.value) * presence;
                  final bool active =
                      (widget.playerDriven
                          ? layout.controller.playerPresented
                          : true) &&
                      progress >= .95 &&
                      routeCurrent;
                  return ExcludeFocus(
                    excluding: !active,
                    child: ExcludeSemantics(
                      excluding: !active,
                      child: IgnorePointer(
                        ignoring: !active,
                        child: SizedBox(
                          key: const ValueKey('desktop-player-actions'),
                          width: width * math.max(0, progress),
                          height: kWindowChromeHeight,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(kWindowChromeHeight / 2),
                            ),
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.centerRight,
                                minWidth: width,
                                maxWidth: width,
                                minHeight: kWindowChromeHeight,
                                maxHeight: kWindowChromeHeight,
                                child: Transform.translate(
                                  key: const ValueKey(
                                    'window-chrome-actions-slide',
                                  ),
                                  offset: Offset(width * (1 - progress), 0),
                                  child: Opacity(
                                    key: const ValueKey(
                                      'window-chrome-actions-fade',
                                    ),
                                    opacity: progress.clamp(0.0, 1.0),
                                    child: _WindowChromeButtonTheme(
                                      child: SizedBox(
                                        width: width,
                                        height: kWindowChromeHeight,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (widget.leading != null) ...[
                                              SizedBox(
                                                width: widget.leadingWidth,
                                                child: Center(
                                                  child: widget.leading,
                                                ),
                                              ),
                                              const _WindowChromeActionDivider(),
                                            ],
                                            for (final child in widget.children)
                                              SizedBox(
                                                width: kWindowChromeButtonWidth,
                                                height: kWindowChromeHeight,
                                                child: child,
                                              ),
                                          ],
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
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      // Keep the artwork/lyrics canvas steady throughout the unfold.
      child: SizedBox(width: width, height: 52),
    );
  }
}

/// The faint hairline that keeps a text command separate from the icons.
class _WindowChromeActionDivider extends StatelessWidget {
  const _WindowChromeActionDivider();

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('window-chrome-action-divider'),
    width: kWindowChromeActionDivider,
    height: kWindowChromeHeight,
    child: Center(
      child: SizedBox(
        width: .5,
        height: 18,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: .18),
          ),
        ),
      ),
    ),
  );
}

/// Keeps the collapse affordance level with the caption, independently of the
/// player's entrance transform. Other layouts retain their normal toolbar.
class WindowChromeCollapse extends StatefulWidget {
  const WindowChromeCollapse({super.key, required this.child});

  final Widget child;

  @override
  State<WindowChromeCollapse> createState() => _WindowChromeCollapseState();
}

class _WindowChromeCollapseState extends State<WindowChromeCollapse> {
  late final _portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) {
    final layout = WindowChromeScope.maybeLayoutOf(context);
    final reveal = layout?.reveal;
    if (layout == null ||
        !layout.inline ||
        reveal == null ||
        TvScope.isActive(context)) {
      return widget.child;
    }
    final bool routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) => Positioned(
        top: kWindowChromeTop,
        left: 16,
        child: Offstage(
          offstage: !routeCurrent,
          child: Listener(
            onPointerDown: (event) =>
                layout.controller.pointerDown(event.pointer),
            onPointerUp: (event) => layout.controller.pointerUp(event.pointer),
            onPointerCancel: (event) =>
                layout.controller.pointerUp(event.pointer),
            child: AnimatedBuilder(
              animation: reveal,
              builder: (context, child) {
                final double progress = 1 - reveal.value;
                final bool active =
                    layout.controller.playerPresented &&
                    progress > 0 &&
                    routeCurrent;
                return ExcludeFocus(
                  excluding: !active,
                  child: ExcludeSemantics(
                    excluding: !active,
                    child: IgnorePointer(
                      ignoring: !active,
                      child: Opacity(
                        opacity: progress.clamp(0.0, 1.0),
                        child: child,
                      ),
                    ),
                  ),
                );
              },
              child: Theme(
                data: layout.chromeTheme ?? Theme.of(context),
                child: _WindowChromeButtonTheme(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      kWindowChromeHeight / 2,
                    ),
                    child: SizedBox(
                      width: kWindowChromeButtonWidth,
                      height: kWindowChromeHeight,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: const SizedBox(width: kWindowChromeButtonWidth, height: 52),
    );
  }
}

class _WindowChromeButtonTheme extends StatelessWidget {
  const _WindowChromeButtonTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(
            Size(kWindowChromeButtonWidth, kWindowChromeHeight),
          ),
          minimumSize: const WidgetStatePropertyAll(Size.zero),
          maximumSize: const WidgetStatePropertyAll(
            Size(kWindowChromeButtonWidth, kWindowChromeHeight),
          ),
          iconSize: const WidgetStatePropertyAll(18),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => scheme.onSurfaceVariant.withValues(
              alpha: states.contains(WidgetState.disabled) ? .4 : 1,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => scheme.onSurface.withValues(
              alpha: states.contains(WidgetState.pressed)
                  ? .13
                  : states.contains(WidgetState.hovered)
                  ? .07
                  : 0,
            ),
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      child: child,
    );
  }
}

/// Fades the title upwards while releasing its height to the page below.
/// A single spring keeps both movements together, including on interruption.
class WindowChromeTransition extends StatefulWidget {
  const WindowChromeTransition({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  State<WindowChromeTransition> createState() => _WindowChromeTransitionState();
}

class _WindowChromeTransitionState extends State<WindowChromeTransition>
    with SingleTickerProviderStateMixin {
  static const _spring = AppleSpring(
    duration: Duration(milliseconds: 500),
    bounce: .08,
  );

  late final _progress = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final _opacity = _progress.drive(const _ClampedOpacity());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = widget.visible ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant WindowChromeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    _progress.springTo(
      widget.visible ? 1 : 0,
      spring: _spring,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: !widget.visible,
    child: ExcludeSemantics(
      excluding: !widget.visible,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _progress,
            builder: (context, child) => Align(
              key: const ValueKey('window-chrome-size'),
              alignment: Alignment.topCenter,
              heightFactor: math.max(0, _progress.value),
              child: FractionalTranslation(
                key: const ValueKey('window-chrome-slide'),
                translation: Offset(0, _progress.value - 1),
                child: child,
              ),
            ),
            child: FadeTransition(
              key: const ValueKey('window-chrome-fade'),
              opacity: _opacity,
              child: widget.child,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ClampedOpacity extends Animatable<double> {
  const _ClampedOpacity();

  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}
