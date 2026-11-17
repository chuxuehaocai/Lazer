import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';

/// An anchored selector with separate current-value and keyboard-focus states.
///
/// MenuAnchor owns the menu lifetime, so replacing a settings page also removes
/// its menu. Unlike a popup route, it can return focus to this exact control.
class SettingsChoice<T> extends StatefulWidget {
  const SettingsChoice({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;

  /// Null disables the control. A null *value* remains a selectable option.
  final ValueChanged<T?>? onChanged;
  final Widget? hint;

  @override
  State<SettingsChoice<T>> createState() => _SettingsChoiceState<T>();
}

class _SettingsChoiceState<T> extends State<SettingsChoice<T>> {
  final MenuController _menu = MenuController();
  final FocusNode _buttonFocus = FocusNode(debugLabel: 'settings-choice');
  bool _focused = false;
  bool _hovered = false;

  bool get _enabled =>
      widget.onChanged != null && widget.items.any((item) => item.enabled);

  @override
  void didUpdateWidget(covariant SettingsChoice<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _menu.isOpen) {
      // Closing the overlay while its anchor is rebuilding would dirty an
      // ancestor. Recheck after the frame in case the control is re-enabled.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_enabled && _menu.isOpen) _menu.close();
      });
    }
  }

  @override
  void dispose() {
    _buttonFocus.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_enabled) return;
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final selectedIndex = widget.items.indexWhere(
      (item) => item.value == widget.value,
    );
    final focusIndex = selectedIndex >= 0 && widget.items[selectedIndex].enabled
        ? selectedIndex
        : widget.items.indexWhere((item) => item.enabled);
    final selected = selectedIndex < 0
        ? null
        : widget.items[selectedIndex].child;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Settings rows may give their trailing widget half of a wide window.
        // Keep the selector and its menu readable without stretching that far.
        final width = math.min(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 240.0,
          math.min(320.0, math.max(0.0, MediaQuery.sizeOf(context).width - 32)),
        );
        return Align(
          alignment: AlignmentDirectional.centerEnd,
          widthFactor: 1,
          heightFactor: 1,
          child: SizedBox(
            width: width,
            child: SemanticsPortal(
              child: MenuAnchor(
                controller: _menu,
                childFocusNode: _buttonFocus,
                useRootOverlay: true,
                consumeOutsideTap: true,
                alignmentOffset: const Offset(0, 6),
                onClose: () {
                  if (mounted && _enabled) _buttonFocus.requestFocus();
                },
                style: MenuStyle(
                  alignment: AlignmentDirectional.bottomStart,
                  backgroundColor: WidgetStatePropertyAll(
                    apple.tertiaryBackground,
                  ),
                  surfaceTintColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  elevation: const WidgetStatePropertyAll(12),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(vertical: 6),
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: apple.separator, width: .5),
                    ),
                  ),
                  minimumSize: WidgetStatePropertyAll(Size(width, 0)),
                  maximumSize: WidgetStatePropertyAll(
                    Size(width, double.infinity),
                  ),
                ),
                menuChildren: [
                  for (var index = 0; index < widget.items.length; index++)
                    _ChoiceOption<T>(
                      item: widget.items[index],
                      selected: index == selectedIndex,
                      autofocus: index == focusIndex,
                      width: width,
                      onSelected: (value) {
                        // MenuItemButton defers its callback until focus has
                        // returned. A layout switch may dispose us meanwhile.
                        if (mounted && _enabled) {
                          widget.onChanged?.call(value);
                        }
                      },
                    ),
                ],
                builder: (context, controller, child) => TvFocusHighlight(
                  borderRadius: BorderRadius.circular(10),
                  child: CallbackShortcuts(
                    // A closed TV selector must leave arrows available for
                    // page traversal; Select opens it before item navigation.
                    bindings: TvScope.isActive(context)
                        ? const {}
                        : {
                            const SingleActivator(LogicalKeyboardKey.arrowDown):
                                _toggle,
                            const SingleActivator(LogicalKeyboardKey.arrowUp):
                                _toggle,
                          },
                    child: Semantics(
                      button: true,
                      enabled: _enabled,
                      expanded: controller.isOpen,
                      child: InkWell(
                        focusNode: _buttonFocus,
                        onTap: _enabled ? _toggle : null,
                        onFocusChange: (value) =>
                            setState(() => _focused = value),
                        onHover: (value) => setState(() => _hovered = value),
                        borderRadius: BorderRadius.circular(10),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _hovered ? apple.secondaryFill : apple.fill,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _focused || controller.isOpen
                                  ? apple.accent
                                  : apple.separator,
                              width: _focused || controller.isOpen ? 1.5 : .5,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: DefaultTextStyle.merge(
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium!
                                        .copyWith(
                                          color: _enabled
                                              ? apple.label
                                              : apple.tertiaryLabel,
                                        ),
                                    child:
                                        selected ??
                                        widget.hint ??
                                        const SizedBox.shrink(),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  controller.isOpen
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  color: apple.secondaryLabel,
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
        );
      },
    );
  }
}

class _ChoiceOption<T> extends StatelessWidget {
  const _ChoiceOption({
    required this.item,
    required this.selected,
    required this.autofocus,
    required this.width,
    required this.onSelected,
  });

  final DropdownMenuItem<T> item;
  final bool selected;
  final bool autofocus;
  final double width;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    return Semantics(
      selected: selected,
      child: TvFocusHighlight(
        borderRadius: BorderRadius.circular(8),
        child: MenuItemButton(
          autofocus: autofocus,
          onPressed: item.enabled ? () => onSelected(item.value) : null,
          onFocusChange: (focused) {
            if (!focused) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Scrollable.ensureVisible(context);
            });
          },
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(width, 44)),
            maximumSize: WidgetStatePropertyAll(Size(width, double.infinity)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return apple.accent.withValues(alpha: .20);
              }
              if (states.contains(WidgetState.hovered)) return apple.fill;
              return selected ? apple.accentSoft : Colors.transparent;
            }),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            side: WidgetStateProperty.resolveWith(
              (states) => BorderSide(
                color: states.contains(WidgetState.focused)
                    ? apple.accent
                    : Colors.transparent,
              ),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          child: SizedBox(
            width: math.max(0, width - 24),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
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
            ),
          ),
        ),
      ),
    );
  }
}
