import 'dart:async';

import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_row.dart';
import '../widgets/spring_buttons.dart';

/// Settings group for the durable lyric file store.
///
/// Those files carry no provider version, so a plugin that starts answering
/// better still shows its older reply until the row expires. This is the only
/// way to make the next play ask again.
class LyricsCacheSettings extends StatefulWidget {
  const LyricsCacheSettings({
    super.key,
    required this.onClear,
    this.onCount,
  });

  /// Deletes every cached lyric file and reports how many were removed.
  final Future<int> Function() onClear;

  /// Reports how many lyric files are currently cached.
  final Future<int> Function()? onCount;

  @override
  State<LyricsCacheSettings> createState() => _LyricsCacheSettingsState();
}

class _LyricsCacheSettingsState extends State<LyricsCacheSettings> {
  bool _clearing = false;
  int? _removed;

  Future<void> _handleTap() async {
    if (_clearing) return;
    int count = 0;
    if (widget.onCount != null) {
      setState(() => _clearing = true);
      try {
        count = await widget.onCount!();
      } catch (_) {
        count = 0;
      } finally {
        if (mounted) setState(() => _clearing = false);
      }
    }
    if (!mounted) return;

    if (count <= 0) {
      await showAppleDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const TrText('清除歌词缓存'),
          content: const TrText('当前暂无已缓存的歌词。'),
          actions: [
            SpringFilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const TrText('关闭'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await showAppleDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const TrText('清除歌词缓存？'),
        content: Text(
          dialogContext
              .tr('确定要清空本地缓存的 {count} 首歌词吗？清除后下次播放将重新从网络获取。')
              .replaceAll('{count}', '$count'),
        ),
        actions: [
          SpringTextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const TrText('取消'),
          ),
          SpringFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const TrText('清除'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _clear();
    }
  }

  Future<void> _clear() async {
    if (_clearing) return;
    setState(() {
      _clearing = true;
      _removed = null;
    });
    int removed = 0;
    try {
      removed = await widget.onClear();
    } catch (_) {
      // Storage may be unavailable; the row simply reports nothing removed.
    }
    if (!mounted) return;
    setState(() {
      _clearing = false;
      _removed = removed;
    });
  }

  String _subtitle(BuildContext context) {
    final int? removed = _removed;
    if (removed == null) return context.tr('下次播放时重新获取歌词');
    return context
        .tr('已清除 {count} 首歌词')
        .replaceAll('{count}', '$removed');
  }

  @override
  Widget build(BuildContext context) {
    return AppleGroupedCard(
      margin: EdgeInsets.zero,
      child: AppleListTile(
        padding: SettingsSpacing.rowPadding,
        minHeight: SettingsSpacing.rowMinHeight,
        title: context.tr('清除歌词缓存'),
        subtitle: _subtitle(context),
        trailing: _clearing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.delete_outline_rounded),
        onTap: _clearing ? null : () => unawaited(_handleTap()),
      ),
    );
  }
}
