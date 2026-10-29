import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'local_media_permission.dart';
import 'local_music_scanner.dart';

/// Scans the platform's usual music folder after asking Android for audio
/// access. When the grant is refused the user can still choose a folder.
Future<void> scanSystemMusic(BuildContext context, AppState state) async {
  const LocalMediaPermission permission = LocalMediaPermission();
  if (!await permission.hasAccess()) {
    final bool granted = await permission.requestAccess();
    if (!granted) {
      if (!context.mounted) return;
      _message(context, '未获得读取音乐权限，请选择一个文件夹导入');
      await pickMusicFolder(context, state);
      return;
    }
  }
  final Directory? root = await LocalMusicScanner().defaultRoot();
  if (root == null) {
    if (!context.mounted) return;
    _message(context, '这台设备没有默认音乐文件夹，请手动选择');
    await pickMusicFolder(context, state);
    return;
  }
  if (!context.mounted) return;
  await scanMusicFolder(context, state, root);
}

Future<void> pickMusicFolder(BuildContext context, AppState state) async {
  String? path;
  try {
    path = await getDirectoryPath(confirmButtonText: context.tr('扫描'));
  } catch (_) {
    if (context.mounted) _message(context, '无法打开文件夹选择器');
    return;
  }
  if (path == null || path.isEmpty || !context.mounted) return;
  await scanMusicFolder(context, state, Directory(path));
}

/// Scans [root], shows progress and merges the result into the local library.
Future<LocalScanResult?> scanMusicFolder(
  BuildContext context,
  AppState state,
  Directory root, {
  bool rememberRoot = true,
}) async {
  final ValueNotifier<int> found = ValueNotifier<int>(0);
  bool stop = false;
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: TrText('扫描本地音乐'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                root.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              ValueListenableBuilder<int>(
                valueListenable: found,
                builder: (BuildContext context, int value, Widget? child) {
                  return TrText('已找到 $value 首');
                },
              ),
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 4),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => stop = true,
            child: TrText('取消'),
          ),
        ],
      ),
    ),
  );
  LocalScanResult result;
  int latestFound = 0;
  final Timer progressTimer = Timer.periodic(
    const Duration(milliseconds: 100),
    (_) {
      if (found.value != latestFound) found.value = latestFound;
    },
  );
  try {
    result = await LocalMusicScanner().scan(
      root,
      existing: state.localLibrary.tracks,
      isCanceled: () => stop,
      onProgress: (int count, String _) => latestFound = count,
    );
  } catch (_) {
    progressTimer.cancel();
    if (navigator.mounted) navigator.pop();
    if (context.mounted) _message(context, '扫描失败，请检查文件夹后重试');
    found.dispose();
    return null;
  }
  progressTimer.cancel();
  found.value = result.tracks.length;
  if (navigator.mounted) navigator.pop();
  found.dispose();
  if (rememberRoot) await state.localLibrary.addScanRoot(root.path);
  await state.localLibrary.addTracks(result.tracks);
  await state.localLibrary.refreshMissing();
  if (!context.mounted) return result;
  if (result.canceled) {
    _message(context, '扫描已取消');
  } else {
    final int total = state.localLibrary.availableCount;
    _message(
      context,
      result.tracks.isEmpty
          ? '没有找到支持的音频文件'
          : '扫描完成 · 共 $total 首本地歌曲',
    );
  }
  return result;
}

void _message(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(context.tr(message))),
  );
}
