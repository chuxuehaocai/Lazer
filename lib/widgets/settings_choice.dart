import 'package:flutter/material.dart';

import '../theme/apple_design.dart';
import 'accessible_controls.dart';

/// Both the closed control and its overlay use the app's grouped material.
class SettingsChoice<T> extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    return SemanticsPortal(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: apple.fill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: apple.separator, width: .5),
        ),
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          isExpanded: true,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(12),
          dropdownColor: apple.tertiaryBackground,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: apple.label),
          icon: Icon(Icons.unfold_more_rounded, color: apple.secondaryLabel),
          menuMaxHeight: 360,
        ),
      ),
    );
  }
}
