import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'app_log.dart';
import 'build_info.dart';
import '../accessibility/lazer_binding.dart';

String diagnosticReport(AppState state) => AppLog.redact(
  [
    'Lazer ${BuildInfo.displayVersion} (${BuildInfo.commit})',
    'Generated: ${DateTime.now().toUtc().toIso8601String()}',
    'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'Dart: ${Platform.version}',
    'Audio engine: ${state.hifi?.status.engineDescription ?? "system"}',
    'Background: ${state.legacyBackground.name}, ${state.browseBackgroundFps} fps',
    'Player background: ${state.playerBackground.name}, ${state.playerBackgroundFps == 0 ? "display refresh rate" : state.playerBackgroundFps} fps',
    'Queue length: ${state.queueLength}',
    if (WidgetsBinding.instance is LazerWidgetsBinding)
      'Accessibility: ${(WidgetsBinding.instance as LazerWidgetsBinding).semanticsDiagnostics}',
    'Playback error: ${state.playbackError ?? "none"}',
    '',
    AppLog.shared.snapshot(),
  ].join('\n'),
);

Future<void> exportLogs(BuildContext context, AppState state) async {
  final text = diagnosticReport(state);
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp(r'[:.]'),
    '-',
  );
  final name = 'Lazer-log-$stamp.txt';
  try {
    if (Platform.isAndroid) {
      final saved = await const MethodChannel(
        'dev.naominet.lazer/logs',
      ).invokeMethod<bool>('export', {'name': name, 'text': text});
      if (saved != true) return;
    } else {
      String? path;
      try {
        path = (await getSaveLocation(
          suggestedName: name,
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Text', extensions: ['txt']),
          ],
        ))?.path;
        if (path == null) return;
      } on UnimplementedError {
        path = '${(await getApplicationDocumentsDirectory()).path}/$name';
      }
      await XFile.fromData(
        Uint8List.fromList(utf8.encode(text)),
        mimeType: 'text/plain',
        name: name,
      ).saveTo(path);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('日志已导出'))));
    }
  } catch (error) {
    AppLog.shared.record('Log export failed: $error');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('日志导出失败，请重试。'))));
    }
  }
}
