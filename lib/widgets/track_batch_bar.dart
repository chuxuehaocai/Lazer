import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/apple_design.dart';

/// A compact floating action strip, matching the lyric selection affordance.
class TrackBatchBar extends StatelessWidget {
  const TrackBatchBar({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.onSelectAll,
    required this.onDownload,
    required this.onClose,
  });

  final int selectedCount;
  final int totalCount;
  final VoidCallback onSelectAll;
  final VoidCallback? onDownload;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    return SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: Material(
          key: const ValueKey<String>('track-batch-bar'),
          color: apple.secondaryGroupedBackground,
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: .2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: apple.separator.withValues(alpha: .45)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.center,
              spacing: 2,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  child: TrText('已选 $selectedCount 首'),
                ),
                TextButton(
                  key: const ValueKey<String>('batch-select-all'),
                  onPressed: onSelectAll,
                  child: TrText(selectedCount == totalCount ? '取消全选' : '全选'),
                ),
                IconButton(
                  key: const ValueKey<String>('batch-download'),
                  tooltip: context.tr('下载所选歌曲'),
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_rounded),
                ),
                IconButton(
                  key: const ValueKey<String>('batch-close'),
                  tooltip: context.tr('退出批量管理'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
