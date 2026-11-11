import 'dart:io';

import '../state/app_state.dart';
import '../storage/app_storage.dart';
import 'app_log.dart';
import 'build_info.dart';

/// Persists a bounded, redacted crash report without requiring a save dialog.
/// This is intentionally best-effort: a crash in diagnostics must never mask
/// the original exception or prevent the fallback error screen from opening.
Future<void> writeCrashDump(
  AppState? state,
  Object error,
  StackTrace stack, {
  String phase = 'uncaught',
}) async {
  try {
    final support = await AppStorage.shared.supportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}crash_dumps',
    );
    await directory.create(recursive: true);
    final now = DateTime.now().toUtc();
    final stamp = now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File(
      '${directory.path}${Platform.pathSeparator}crash-$stamp.log',
    );
    final current = state?.current;
    final report = AppLog.redact(
      [
        'Lazer ${BuildInfo.displayVersion} (${BuildInfo.commit})',
        'Generated: ${now.toIso8601String()}',
        'Phase: $phase',
        'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        'Dart: ${Platform.version}',
        'Developer console: ${state?.developerConsoleEnabled == true ? "enabled" : "disabled"}',
        'Audio engine: ${state?.hifi?.status.engineDescription ?? "system"}',
        'Playing: ${state?.playing ?? false}',
        'Audio ready: ${state?.audioReady ?? false}',
        'Track: ${current?.title ?? "none"} (${current?.id ?? ""})',
        'Position: ${state?.precisePosition.inMilliseconds ?? 0} ms',
        'Queue: ${state?.queueIndex ?? 0}/${state?.queueLength ?? 0}',
        'Volume: ${state == null ? "unknown" : (state.volume * 100).round()}%',
        'Playback error: ${state?.playbackError ?? "none"}',
        '',
        'Error: $error',
        'Stack trace:',
        '$stack',
        '',
        'Recent log:',
        AppLog.shared.snapshot(),
      ].join('\n'),
    );
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(report, flush: true);
    await temporary.rename(file.path);
    AppLog.shared.record('Crash dump written: ${file.path}');

    final files = await directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.log'))
        .toList();
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    for (final old in files.skip(5)) {
      try {
        await old.delete();
      } catch (_) {}
    }
  } catch (_) {
    // Crash reporting is deliberately non-throwing.
  }
}
