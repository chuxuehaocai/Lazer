import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';

/// The app's select control: the current value sits in a pill and the options
/// open as a menu hanging directly off it, the way a dropdown behaves.
///
/// The same rounded pill is used on desktop, mobile and in plugin pages, so the
/// options ride on [showMenu] instead of Flutter's selector. The menu keeps
/// long translated labels readable (two lines, then an ellipsis) and scrolls by
/// itself when the list is taller than the screen.
class SettingsChoice<T> extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;

  /// Null disables the control: the pill greys out and no menu opens.
  final ValueChanged<T?>? onChanged;
  final Widget? hint;

  /// Opens the options directly under [anchor], as wide as the pill.
  Future<void> _open(BuildContext anchor, double width) async {
    final ValueChanged<T?>? changed = onChanged;
    if (changed == null || items.isEmpty) return;
    final RenderBox button = anchor.findRenderObject()! as RenderBox;
    final NavigatorState navigator = Navigator.of(anchor);
    final RenderBox overlay =
        navigator.overlay!.context.findRenderObject()! as RenderBox;
    final Rect pill = Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    // The menu reports a null result for "dismissed", so the options travel as
    // a wrapper: a legitimately null value — 系统默认 in the output picker — has
    // to stay selectable.
    final _ChoiceValue<T>? picked = await showMenu<_ChoiceValue<T>>(
      context: anchor,
      // Below the pill, sharing its left edge and its width: a menu is read as
      // part of the control it drops out of, not as a window of its own.
      position: RelativeRect.fromLTRB(
        pill.left,
        pill.bottom + 6,
        overlay.size.width - pill.right,
        overlay.size.height - pill.bottom,
      ),
      items: <PopupMenuEntry<_ChoiceValue<T>>>[
        for (final DropdownMenuItem<T> item in items)
          PopupMenuItem<_ChoiceValue<T>>(
            value: _ChoiceValue<T>(item.value),
            enabled: item.enabled,
            child: _OptionTile(item: item, selected: item.value == value),
          ),
      ],
      initialValue: _ChoiceValue<T>(value),
      color: AppleSemanticColors.of(anchor).tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      // Grows past the pill only when an option needs the room; the cap keeps a
      // long translated label from turning the menu into a banner.
      constraints: BoxConstraints(
        minWidth: width,
        maxWidth: math.max(width, 320),
      ),
    );
    if (picked != null) changed(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Widget? selected = items
        .where((DropdownMenuItem<T> item) => item.value == value)
        .firstOrNull
        ?.child;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool enabled = onChanged != null && items.isNotEmpty;
        // A control placed in an unbounded slot still needs a menu width.
        final double width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 240;
        return SemanticsPortal(
          child: TvFocusHighlight(
            borderRadius: BorderRadius.circular(10),
            child: Semantics(
              button: true,
              enabled: enabled,
              child: InkWell(
                onTap: enabled ? () => _open(context, width) : null,
                borderRadius: BorderRadius.circular(10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: apple.fill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: enabled
                          ? apple.separator
                          : apple.separator.withValues(alpha: .5),
                      width: .5,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: DefaultTextStyle.merge(
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium!
                                .copyWith(
                                  color: enabled
                                      ? apple.label
                                      : apple.tertiaryLabel,
                                ),
                            child:
                                selected ?? hint ?? const SizedBox.shrink(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.unfold_more_rounded,
                          color: apple.secondaryLabel,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The value one menu option stands for.
///
/// [showMenu] hands back null when the menu is dismissed, so an option whose
/// own value is null could never be told apart from "closed without picking".
/// Wrapping every value keeps that case selectable.
@immutable
class _ChoiceValue<T> {
  const _ChoiceValue(this.value);

  final T? value;

  @override
  bool operator ==(Object other) =>
      other is _ChoiceValue<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// One option in the menu: the tick marks the value the control is showing.
class _OptionTile<T> extends StatelessWidget {
  const _OptionTile({required this.item, required this.selected});

  final DropdownMenuItem<T> item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 22,
          child: selected
              ? Icon(Icons.check_rounded, size: 18, color: apple.accent)
              : null,
        ),
        Expanded(
          child: DefaultTextStyle.merge(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              color: item.enabled ? apple.label : apple.tertiaryLabel,
            ),
            child: item.child,
          ),
        ),
      ],
    );
  }
}
