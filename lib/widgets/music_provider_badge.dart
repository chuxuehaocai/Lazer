import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/shape_scale.dart';

class ExperimentalMusicBadge extends StatelessWidget {
  const ExperimentalMusicBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6 * AppleShape.scaleOf(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: TrText(
          '实验性',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
