import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'imported_lyrics_store.dart';

const XTypeGroup _lyricsTypes = XTypeGroup(
  label: '歌词',
  extensions: <String>['lrc', 'txt'],
  // iOS needs a UTI; without one `openFile` throws before showing a picker.
  uniformTypeIdentifiers: <String>['public.plain-text'],
);

/// Lets the user pick a `.lrc`, validates it and stores it for [track].
Future<bool> pickAndImportLyrics(
  BuildContext context,
  AppState state, {
  Track? track,
}) async {
  final Track? target = track ?? state.current;
  if (target == null) return false;
  XFile? file;
  try {
    file = await openFile(acceptedTypeGroups: const <XTypeGroup>[_lyricsTypes]);
  } catch (_) {
    if (context.mounted) _notify(context, '无法打开文件选择器');
    return false;
  }
  if (file == null) return false;
  String text;
  try {
    text = decodeLyricsBytes(await file.readAsBytes());
  } on FormatException {
    if (context.mounted) _notify(context, '歌词编码无法识别，请另存为 UTF-8 后重试');
    return false;
  } catch (_) {
    if (context.mounted) _notify(context, '无法读取这个文件');
    return false;
  }
  final bool saved = await state.saveImportedLyrics(target, text);
  if (!context.mounted) return saved;
  _notify(context, saved ? '已导入歌词' : '文件里没有可用的时间轴歌词');
  return saved;
}

Future<void> removeImportedLyrics(
  BuildContext context,
  AppState state,
  Track track,
) async {
  await state.clearImportedLyrics(track);
  if (!context.mounted) return;
  _notify(context, '已移除导入的歌词');
}

void _notify(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(context.tr(message))));
}
