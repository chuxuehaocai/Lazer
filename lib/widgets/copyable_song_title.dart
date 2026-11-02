import 'spring_buttons.dart';
import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

/// Wraps a song title with the long-press copy affordance.
///
/// A quick tap still reaches the row or bar underneath: only a long press
/// opens the confirmation sheet. The title itself is handed to the dialog so
/// the exact string that is shown is the string that gets copied.
class CopyableSongTitle extends StatelessWidget {
  const CopyableSongTitle({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onLongPress: () => showCopySongTitleDialog(context, title),
    child: child,
  );
}

/// Asks before copying [title], then confirms with a snack bar.
///
/// The sheet is a rounded rectangle with the same soft elevation language as
/// the player's floating cards.
Future<void> showCopySongTitleDialog(BuildContext context, String title) async {
  final bool? copy = await showAppleDialog<bool>(
    context: context,
    builder: (BuildContext context) => Dialog(
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: .5),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.tr('复制歌曲名'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                context.tr('是否复制歌曲名？'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  SpringTextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const TrText('取消'),
                  ),
                  const SizedBox(width: 8),
                  SpringFilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const TrText('复制'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (copy != true || !context.mounted) return;
  await Clipboard.setData(ClipboardData(text: title));
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.tr('已复制歌曲名'))));
}
