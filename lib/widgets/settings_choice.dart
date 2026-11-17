import 'package:flutter/material.dart';

import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';

/// Both the closed control and its overlay use the app's grouped material.
///
/// This intentionally does not use Flutter's built-in selector. The same
/// rounded control is used on desktop, mobile and in plugin pages, while the
/// option sheet keeps long translated labels readable on narrow displays.
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
  final ValueChanged<T?>? onChanged;
  final Widget? hint;

  Future<void> _open(BuildContext context) async {
    if (onChanged == null || items.isEmpty) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        final apple = AppleSemanticColors.of(sheetContext);
        return SafeArea(
          minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
              child: Material(
                color: apple.tertiaryBackground,
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(18),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => Divider(
                    height: .5,
                    indent: 16,
                    endIndent: 16,
                    color: apple.separator,
                  ),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final selected = item.value == value;
                    return Semantics(
                      button: true,
                      selected: selected,
                      enabled: item.enabled,
                      child: InkWell(
                        onTap: item.enabled
                            ? () => Navigator.of(sheetContext).pop(index)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 13, 16, 13),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: DefaultTextStyle.merge(
                                  style: Theme.of(context).textTheme.bodyLarge!
                                      .copyWith(color: apple.label),
                                  child: item.child,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                selected
                                    ? Icons.check_rounded
                                    : Icons.chevron_right_rounded,
                                size: 20,
                                color: selected
                                    ? apple.accent
                                    : apple.tertiaryLabel,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
    if (selected != null && selected >= 0 && selected < items.length) {
      onChanged!(items[selected].value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final selected = items
        .where((item) => item.value == value)
        .firstOrNull
        ?.child;
    return SemanticsPortal(
      child: TvFocusHighlight(
        borderRadius: BorderRadius.circular(10),
        child: Semantics(
          button: true,
          enabled: onChanged != null,
          child: InkWell(
            onTap: onChanged == null ? null : () => _open(context),
            borderRadius: BorderRadius.circular(10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: apple.fill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: onChanged == null
                      ? apple.separator.withValues(alpha: .5)
                      : apple.separator,
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
                        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                          color: onChanged == null
                              ? apple.tertiaryLabel
                              : apple.label,
                        ),
                        child: selected ?? hint ?? const SizedBox.shrink(),
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
  }
}
