import 'build_safe_state.dart';
import 'package:flutter/material.dart';
import '../animation/view_transitions.dart';
import 'package:flutter/services.dart';
import '../animation/apple_spring.dart';
import '../navigation/system_back_gesture.dart';

import 'accessible_controls.dart';
import 'shared_browse_background.dart';

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

class _SettingsDetailHostState extends State<SettingsDetailHost>
    with SingleTickerProviderStateMixin, BuildSafeState<SettingsDetailHost> {
  final _storage = PageStorageBucket();
  final _backProgress = ValueNotifier<double?>(null);
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
  WidgetBuilder? _detail;
  LocalHistoryEntry? _history;
  bool _disposing = false;
  int _generation = 0;

  void _open(WidgetBuilder builder) {
    if (_history == null) {
      _history = LocalHistoryEntry(onRemove: _closed);
      ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
    }
    setState(() {
      _detail = builder;
      _generation++;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _transition.value = 1;
    } else {
      _transition.springTo(1, spring: AppleSpring.responsive);
    }
  }

  void _close() => _history?.remove();

  void _closed() {
    _history = null;
    if (!mounted || _disposing) return;
    final immediate =
        MediaQuery.disableAnimationsOf(context) ||
        (_backProgress.value ?? 0) >= 1;
    setState(() {
      if (immediate || _transition.isDismissed) _detail = null;
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
        _detail != null &&
        mounted &&
        !_disposing) {
      setState(() => _detail = null);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _history?.remove();
    _backProgress.dispose();
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final active = _history != null;
    return SystemBackGesture(
      canStart: () =>
          mounted &&
          _history != null &&
          _transition.isCompleted &&
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
                  // Keep the overview mounted so its scroll and controls do not
                  // have to restore themselves on the first return frame.
                  AnimatedBuilder(
                    animation: _transition,
                    builder: (context, child) => Offstage(
                      offstage: _overviewOpacity.value == 0,
                      child: TickerMode(
                        enabled: _overviewOpacity.value != 0,
                        child: child!,
                      ),
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
                  ),
                  if (detail != null)
                    ExcludeFocus(
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
                                // Retain the embedded scope until the exit has
                                // finished, never replacing it with a Scaffold.
                                child: _SettingsDetailScope(
                                  key: ValueKey(_generation),
                                  open: _open,
                                  close: _close,
                                  child: Focus(
                                    autofocus: true,
                                    child: Builder(builder: detail),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
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
  });
  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final close = context
        .dependOnInheritedWidgetOfExactType<_SettingsDetailScope>()
        ?.close;
    if (close == null) {
      return Scaffold(
        backgroundColor: BrowseBackgroundScope.contains(context)
            ? Colors.transparent
            : null,
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              if (Navigator.of(context).canPop())
                Positioned(
                  top: 8,
                  left: 8,
                  child: AccessibleIconButton(
                    key: const ValueKey('settings-detail-back'),
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: Navigator.of(context).canPop() ? 56 : 0,
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inset = constraints.maxWidth < 600 ? 20.0 : 32.0;
          return Column(
            key: const ValueKey('settings-detail-subview'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(inset - 12, 8, inset, 0),
                child: Row(
                  children: [
                    AccessibleIconButton(
                      key: const ValueKey('settings-detail-back'),
                      tooltip: '返回',
                      onPressed: close,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(child: child),
            ],
          );
        },
      ),
    );
  }
}
