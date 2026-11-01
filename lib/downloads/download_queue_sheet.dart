import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/audio_quality.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import 'download_manager.dart';

/// Opens the queue as a dialog on wide screens and as a bottom sheet on phones.
Future<void> showDownloadQueueSheet(BuildContext context, AppState state) {
  final bool wide = MediaQuery.sizeOf(context).width >= 700;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 520,
          height: 560,
          child: DownloadQueueView(
            state: state,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (BuildContext context) => SizedBox(
      height: math.min(MediaQuery.sizeOf(context).height * .82, 620),
      child: DownloadQueueView(
        state: state,
        onClose: () => Navigator.of(context).pop(),
      ),
    ),
  );
}

class DownloadQueueView extends StatelessWidget {
  const DownloadQueueView({super.key, required this.state, this.onClose});

  final AppState state;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AnimatedBuilder(
      animation: state.downloadManager,
      builder: (BuildContext context, Widget? child) {
        final DownloadManager manager = state.downloadManager;
        final List<DownloadTask> tasks = manager.tasks;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          context.tr('下载任务'),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          context.tr(
                            manager.activeCount > 0
                                ? '${manager.activeCount} 个进行中 · ${manager.completedCount} 个已完成'
                                : '${manager.completedCount} 个已完成',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: apple.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (tasks.any((DownloadTask task) => task.isDone))
                    TextButton(
                      onPressed: manager.clearFinished,
                      child: TrText('清空已完成'),
                    ),
                  if (onClose != null)
                    IconButton(
                      tooltip: context.tr('关闭'),
                      onPressed: onClose,
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                ],
              ),
            ),
            if (tasks.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.download_done_rounded,
                        size: 34,
                        color: apple.tertiaryLabel,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        context.tr('暂无下载任务'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: apple.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: apple.separator),
                  itemBuilder: (BuildContext context, int index) =>
                      _DownloadRow(manager: manager, task: tasks[index]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.manager, required this.task});

  final DownloadManager manager;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final AudioQuality granted = task.resolvedQuality ?? task.requestedQuality;
    final String? degraded =
        task.resolvedQuality != null &&
            task.resolvedQuality != task.requestedQuality
        ? context.tr('${context.tr(granted.label)}（已降级）')
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              switch (task.status) {
                DownloadStatus.completed => Icons.check_circle_rounded,
                DownloadStatus.existing => Icons.check_circle_outline_rounded,
                DownloadStatus.failed => Icons.error_outline_rounded,
                DownloadStatus.canceled => Icons.cancel_outlined,
                DownloadStatus.downloading => Icons.downloading_rounded,
                _ => Icons.schedule_rounded,
              },
              size: 19,
              color: switch (task.status) {
                DownloadStatus.completed => apple.accent,
                DownloadStatus.failed => theme.colorScheme.error,
                _ => apple.secondaryLabel,
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  task.track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  <String>[
                    degraded ?? granted.bitrateLabel,
                    _statusText(context, task),
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: task.status == DownloadStatus.failed
                        ? theme.colorScheme.error
                        : apple.secondaryLabel,
                  ),
                ),
                if (task.status == DownloadStatus.downloading) ...<Widget>[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 4,
                      backgroundColor: apple.fill,
                      color: apple.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (task.isActive)
            IconButton(
              tooltip: context.tr('取消'),
              onPressed: () => manager.cancel(task),
              icon: const Icon(Icons.close_rounded, size: 18),
            )
          else if (task.status == DownloadStatus.failed ||
              task.status == DownloadStatus.canceled)
            IconButton(
              tooltip: context.tr('重试'),
              onPressed: () => manager.retry(task),
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
        ],
      ),
    );
  }

  String _statusText(BuildContext context, DownloadTask task) =>
      switch (task.status) {
        DownloadStatus.queued => context.tr('等待中'),
        DownloadStatus.resolving => context.tr('正在获取地址…'),
        DownloadStatus.downloading =>
          task.total > 0
              ? '${formatBytes(task.received)} / ${formatBytes(task.total)}'
              : formatBytes(task.received),
        DownloadStatus.completed => context.tr(
          '已下载 · ${formatBytes(task.total)}',
        ),
        DownloadStatus.existing => context.tr('文件已存在，未覆盖'),
        DownloadStatus.failed => context.tr(task.error ?? '下载失败'),
        DownloadStatus.canceled => context.tr('已取消'),
      };
}
