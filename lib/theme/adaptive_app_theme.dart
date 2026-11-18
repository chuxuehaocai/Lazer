import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../tv/tv_mode.dart';
import 'apple_design.dart';
import 'lazer_theme.dart';

/// Applied below UiScaling, above the navigator so pushed pages and dialogs
/// use the same phone palette as the shell at its effective layout width.
class AdaptiveAppTheme extends StatelessWidget {
  const AdaptiveAppTheme({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final compact =
        !largeScreenModeOf(context) &&
        !state.deviceIsWatch &&
        useCompactLayout(
          state.uiMode,
          MediaQuery.sizeOf(context).width,
          layoutStyle: state.layoutStyle,
        );
    return Theme(
      data: compact
          ? buildAppleTheme(
              brightness: inherited.brightness,
              compact: true,
              seedAccent: state.accentSeed,
              fonts: state.fontPreferences,
              ui: state.pluginTheme ?? LazerThemeTokens.apple,
            )
          : inherited,
      child: child,
    );
  }
}
