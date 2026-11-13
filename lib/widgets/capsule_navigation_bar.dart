import 'dart:math' as math;
import 'dart:ui' show SemanticsRole, lerpDouble;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../animation/apple_spring.dart';
import '../theme/apple_design.dart';
import 'apple_ui.dart';
import 'interaction_feedback.dart';

/// Floating navigation with an inline label on the selected tab only.
class CapsuleNavigationBar extends StatefulWidget {
  const CapsuleNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.iconOnly = false,
  }) : assert(destinations.length >= 2),
       assert(selectedIndex >= 0 && selectedIndex < destinations.length);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  /// When the available width is tight, keep every tab equal and show only
  /// the selected icon with a circular highlight.
  final bool iconOnly;

  @override
  State<CapsuleNavigationBar> createState() => _CapsuleNavigationBarState();
}

class _CapsuleNavigationBarState extends State<CapsuleNavigationBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    value: 1,
  );
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: _motion,
    curve: const AppleSpringCurve(),
  );
  late List<double> _from = List.generate(
    widget.destinations.length,
    (index) => index == widget.selectedIndex ? 1 : 0,
  );
  late double _indicatorFrom = widget.selectedIndex.toDouble();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _motion.isAnimating) {
      _motion.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant CapsuleNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.destinations.length != oldWidget.destinations.length) {
      _from = List.generate(
        widget.destinations.length,
        (index) => index == widget.selectedIndex ? 1 : 0,
      );
      _indicatorFrom = widget.selectedIndex.toDouble();
      _motion.value = 1;
    } else if (widget.selectedIndex != oldWidget.selectedIndex) {
      // Retarget the positions on screen, including an interrupted selection.
      final progress = _progress.value;
      _from = [
        for (var index = 0; index < _from.length; index++)
          lerpDouble(
            _from[index],
            index == oldWidget.selectedIndex ? 1 : 0,
            progress,
          )!,
      ];
      _indicatorFrom = lerpDouble(
        _indicatorFrom,
        oldWidget.selectedIndex.toDouble(),
        progress,
      )!;
      if (MediaQuery.disableAnimationsOf(context)) {
        _motion.value = 1;
      } else {
        _motion.duration = MotionTiming.scale(
          const Duration(milliseconds: 300),
        );
        _motion.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selectedColor = Color.alphaBlend(
      apple.accent.withValues(alpha: .12),
      apple.label.withValues(alpha: dark ? .28 : .14),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool iconOnly =
            widget.iconOnly ||
            (constraints.maxWidth.isFinite && constraints.maxWidth < 280);
        return RepaintBoundary(
          child: AppleGlass(
            borderRadius: BorderRadius.circular(999),
            color: apple.glassStrong,
            border: Border.all(color: apple.separator, width: .5),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: SizedBox(
                height: 44,
                child: Semantics(
                  container: true,
                  role: SemanticsRole.tabBar,
                  explicitChildNodes: true,
                  child: CustomMultiChildLayout(
                    // One clock moves the indicator and all tabs. Ticks lay out
                    // this small bar without rebuilding text, icons or the page.
                    delegate: _CapsuleLayout(
                      progress: _progress,
                      from: _from,
                      selectedIndex: widget.selectedIndex,
                      indicatorFrom: _indicatorFrom,
                      iconOnly: iconOnly,
                    ),
                    children: [
                      LayoutId(
                        id: 'indicator',
                        child: DecoratedBox(
                          key: const ValueKey('capsule-navigation-indicator'),
                          decoration: BoxDecoration(
                            color: selectedColor,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: apple.accent.withValues(alpha: .28),
                              width: .75,
                            ),
                          ),
                        ),
                      ),
                      for (
                        var index = 0;
                        index < widget.destinations.length;
                        index++
                      )
                        LayoutId(
                          id: index,
                          child: _destination(
                            context,
                            index,
                            Tween<double>(
                              begin: _from[index],
                              end: index == widget.selectedIndex ? 1 : 0,
                            ).animate(_progress),
                            iconOnly: iconOnly,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _destination(
    BuildContext context,
    int index,
    Animation<double> weight, {
    required bool iconOnly,
  }) {
    final destination = widget.destinations[index];
    final selected = index == widget.selectedIndex;
    final apple = AppleSemanticColors.of(context);
    final color = selected ? apple.label : apple.secondaryLabel;
    final onTap = destination.enabled
        ? feedbackAction(context, () => widget.onDestinationSelected(index))
        : null;
    return Semantics(
      container: true,
      role: SemanticsRole.tab,
      label: destination.label,
      selected: selected,
      enabled: destination.enabled,
      onTap: onTap,
      excludeSemantics: true,
      // The browser draws its tooltip through a separate overlay, which a
      // phone-width page can end up showing over the whole shell; the tab
      // label is already visible when it matters.
      child: _withTooltip(
        destination.tooltip ?? destination.label,
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: IconTheme(
              data: IconThemeData(size: 22, color: color),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  selected
                      ? destination.selectedIcon ?? destination.icon
                      : destination.icon,
                  if (!iconOnly)
                    Flexible(
                      child: SizeTransition(
                        axis: Axis.horizontal,
                        alignment: Alignment.centerLeft,
                        sizeFactor: weight,
                        child: FadeTransition(
                          opacity: weight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  destination.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: color,
                                      ),
                                ),
                              ),
                            ],
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

  Widget _withTooltip(String message, Widget child) => kIsWeb
      ? child
      : Tooltip(message: message, excludeFromSemantics: true, child: child);
}

class _CapsuleLayout extends MultiChildLayoutDelegate {
  _CapsuleLayout({
    required this.progress,
    required this.from,
    required this.selectedIndex,
    required this.indicatorFrom,
    required this.iconOnly,
  }) : super(relayout: progress);

  final Animation<double> progress;
  final List<double> from;
  final int selectedIndex;
  final double indicatorFrom;
  final bool iconOnly;

  @override
  void performLayout(Size size) {
    if (iconOnly) {
      final cell = size.width / from.length;
      layoutChild(
        'indicator',
        BoxConstraints.tightFor(width: size.height, height: size.height),
      );
      positionChild(
        'indicator',
        Offset(
          lerpDouble(indicatorFrom, selectedIndex.toDouble(), progress.value)! *
                  cell +
              (cell - size.height) / 2,
          0,
        ),
      );
      for (var index = 0; index < from.length; index++) {
        layoutChild(
          index,
          BoxConstraints.tightFor(width: cell, height: size.height),
        );
        positionChild(index, Offset(index * cell, 0));
      }
      return;
    }
    final minimum = math.min(44.0, size.width / from.length);
    final selectedWidth = math.min(
      108.0,
      size.width - minimum * (from.length - 1),
    );
    final iconWidth = (size.width - selectedWidth) / (from.length - 1);
    final t = progress.value;
    layoutChild(
      'indicator',
      BoxConstraints.tightFor(width: selectedWidth, height: size.height),
    );
    positionChild(
      'indicator',
      Offset(
        lerpDouble(indicatorFrom, selectedIndex.toDouble(), t)! * iconWidth,
        0,
      ),
    );
    var left = 0.0;
    for (var index = 0; index < from.length; index++) {
      final weight = lerpDouble(
        from[index],
        index == selectedIndex ? 1 : 0,
        t,
      )!;
      final width = iconWidth + (selectedWidth - iconWidth) * weight;
      layoutChild(
        index,
        BoxConstraints.tightFor(width: width, height: size.height),
      );
      positionChild(index, Offset(left, 0));
      left += width;
    }
  }

  @override
  bool shouldRelayout(_CapsuleLayout oldDelegate) =>
      progress != oldDelegate.progress ||
      from != oldDelegate.from ||
      selectedIndex != oldDelegate.selectedIndex ||
      indicatorFrom != oldDelegate.indicatorFrom ||
      iconOnly != oldDelegate.iconOnly;
}
