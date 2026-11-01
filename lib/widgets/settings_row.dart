import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';

/// Shared spacing for settings rows and neighboring grouped cards.
abstract final class SettingsSpacing {
  static const double groupGap = 16;
  static const double rowMinHeight = 72;
  static const EdgeInsets rowPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 12,
  );
}

/// A settings label and control, with room for both on narrow displays.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.trailing,
    this.controlFlex = 9,
  });

  final String label;
  final String subtitle;
  final Widget trailing;
  final int controlFlex;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Widget heading = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          context.tr(label),
          style: theme.textTheme.bodyLarge?.copyWith(color: apple.label),
        ),
        if (subtitle.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            context.tr(subtitle),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
        ],
      ],
    );
    return TvFocusHighlight(
      borderRadius: BorderRadius.circular(10),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Use the actual card width: settings can be shown in an inset
          // pane even when the window itself is much wider.
          final bool stacked = constraints.maxWidth < 360;
          return Container(
            constraints: const BoxConstraints(
              minHeight: SettingsSpacing.rowMinHeight,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: apple.separator, width: .5),
              ),
            ),
            padding: SettingsSpacing.rowPadding,
            child: stacked
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      heading,
                      const SizedBox(height: 8),
                      Align(alignment: Alignment.centerLeft, child: trailing),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(flex: 4, child: heading),
                      const SizedBox(width: 12),
                      Flexible(
                        flex: controlFlex,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: trailing,
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}
