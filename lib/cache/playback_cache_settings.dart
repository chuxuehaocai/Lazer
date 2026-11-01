import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/apple_ui.dart';
import 'playback_cache.dart';

/// Standalone settings group for the shared settings page.
class PlaybackCacheSettings extends StatelessWidget {
  const PlaybackCacheSettings({super.key, required this.controller});

  final PlaybackCacheController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[controller, controller.library]),
      builder: (BuildContext context, Widget? child) => AppleGroupedCard(
        margin: EdgeInsets.zero,
        child: Column(
          children: <Widget>[
            ListTile(
              title: Text(context.tr('边听边缓存')),
              subtitle: Text(context.tr('完整缓存可在本地音乐中离线播放')),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<PlaybackCacheMode>(
                  key: const ValueKey<String>('playback-cache-mode'),
                  value: controller.mode,
                  items: <DropdownMenuItem<PlaybackCacheMode>>[
                    DropdownMenuItem(
                      value: PlaybackCacheMode.recent,
                      child: Text(context.tr('最近缓存')),
                    ),
                    DropdownMenuItem(
                      value: PlaybackCacheMode.intelligent,
                      child: Text(context.tr('智能缓存')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) unawaited(controller.setMode(value));
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                context.tr(
                  controller.mode == PlaybackCacheMode.recent
                      ? '超过上限时移除最久没听的歌曲'
                      : '优先保留最近 30 天内听得更多的歌曲',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            ListTile(
              title: Text(context.tr('缓存歌曲上限')),
              subtitle: Text(context.tr('当前已缓存 ${controller.cachedCount} 首')),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const ValueKey<String>('playback-cache-limit'),
                  value: controller.maximumTracks,
                  items: <DropdownMenuItem<int>>[
                    for (final int count in <int>{
                      10,
                      25,
                      50,
                      100,
                      200,
                      500,
                      controller.maximumTracks,
                    }.toList()..sort())
                      DropdownMenuItem(
                        value: count,
                        child: Text(context.tr('$count 首')),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(controller.setMaximumTracks(value));
                    }
                  },
                ),
              ),
            ),
            ListTile(
              title: Text(context.tr('清空播放缓存')),
              subtitle: Text(context.tr('手动下载和导入的文件会保留')),
              trailing: const Icon(Icons.delete_outline_rounded),
              onTap: controller.cachedCount == 0
                  ? null
                  : () => unawaited(controller.clear()),
            ),
          ],
        ),
      ),
    );
  }
}
