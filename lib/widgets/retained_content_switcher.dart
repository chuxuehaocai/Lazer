import 'package:flutter/material.dart';

import '../animation/motion_snapshot.dart';
import '../animation/view_transitions.dart';

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
  });

  final String currentKey;
  final Widget page;
  final Set<String> retainKeys;
  final Duration duration;
  final double slideFraction;

  @override
  State<RetainedContentSwitcher> createState() =>
      _RetainedContentSwitcherState();
}

class _RetainedPage {
  _RetainedPage(this.page);
  Widget page;
  double from = 1;
  double to = 1;
  FocusNode? lastFocus;
  bool get transitioning => from != to;
}

class _RetainedContentSwitcherState extends State<RetainedContentSwitcher>
    with SingleTickerProviderStateMixin {
  final Map<String, _RetainedPage> _pages = <String, _RetainedPage>{};
  late final AnimationController _motion = AnimationController(vsync: this)
    ..addStatusListener(_status);

  @override
  void initState() {
    super.initState();
    _pages[widget.currentKey] = _RetainedPage(widget.page);
    _motion.value = 1;
  }

  double _value(_RetainedPage entry) =>
      entry.from +
      (entry.to - entry.from) * ViewMotion.curve.transform(_motion.value);

  void _status(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _pages.removeWhere(
        (key, _) =>
            key != widget.currentKey && !widget.retainKeys.contains(key),
      );
      for (final entry in _pages.values) {
        entry.from = entry.to;
      }
    });
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
    for (final entry in _pages.values) {
      entry.from = _value(entry);
      entry.to = 0;
    }
    final incoming = _pages.putIfAbsent(
      widget.currentKey,
      () => _RetainedPage(widget.page)..from = 0,
    );
    incoming.to = 1;
    _motion.duration = widget.duration;
    if (widget.duration == Duration.zero) {
      _motion.value = 1;
      _pages.removeWhere(
        (key, _) =>
            key != widget.currentKey && !widget.retainKeys.contains(key),
      );
      for (final entry in _pages.values) {
        entry.from = entry.to;
      }
    } else {
      _motion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      for (final item in _pages.entries) _page(item.key, item.value),
    ],
  );

  Widget _page(String key, _RetainedPage entry) {
    final current = key == widget.currentKey;
    final animation = _motion
        .drive(CurveTween(curve: ViewMotion.curve))
        .drive(Tween<double>(begin: entry.from, end: entry.to));
    return Offstage(
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
                opacity: animation,
                child: SlideTransition(
                  position: animation.drive(
                    Tween<Offset>(
                      begin: Offset(0, widget.slideFraction),
                      end: Offset.zero,
                    ),
                  ),
                  child: MotionSnapshot(
                    animation: _motion,
                    child: RepaintBoundary(child: entry.page),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
