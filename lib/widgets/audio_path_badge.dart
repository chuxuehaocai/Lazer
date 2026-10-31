import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';

/// Says, in the player itself, that this session is not on the HiFi path.
///
/// Renders nothing while the native engine drives playback, so its presence is
/// never ambiguous — a downgrade to `just_audio` is only acceptable if the person
/// listening can see that it happened (see `docs/audio-engine-status.md`).
///
/// The text comes from [AppState.hifiPathNotice]: the launch-time reason when the
/// native engine could not start, or the failure that ended a running native
/// session.
class AudioPathBadge extends StatelessWidget {
  const AudioPathBadge({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.all,
    builder: (BuildContext context, Widget? _) {
      final String? notice = state.hifiPathNotice;
      if (notice == null) {
        return const SizedBox.shrink(key: ValueKey('hifi-path-native'));
      }
      final AppleSemanticColors apple = AppleSemanticColors.of(context);
      return Padding(
        key: const ValueKey('hifi-path-fallback'),
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.info_outline_rounded, size: 15, color: apple.secondaryLabel),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${context.tr('非 HiFi 路径')} · $notice',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
              ),
            ),
          ],
        ),
      );
    },
  );
}
