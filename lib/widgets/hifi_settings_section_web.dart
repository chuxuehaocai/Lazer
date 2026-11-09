import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// The browser has no native output device catalog, so the HiFi group is not
/// drawn on the web. The shared settings page still mounts this section.
class HifiSettingsSection extends StatelessWidget {
  const HifiSettingsSection({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
