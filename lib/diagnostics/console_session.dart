import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/app_state.dart';
import 'app_log.dart';
import 'developer_console.dart';
import 'export_logs.dart';

/// The same view can inspect a local session or a session in the main engine.
abstract class ConsoleSession extends ChangeNotifier {
  bool get enabled;
  bool get busy;
  List<ConsoleEntry> get entries;
  List<String> get history;
  String get logs;
  Future<void> execute(String input);
  Future<void> clearLogs();
  Future<String> report();
}

class LocalConsoleSession extends ConsoleSession {
  LocalConsoleSession(this.state) {
    state.addListener(_schedule);
    state.developerConsole.addListener(_schedule);
    _logs = AppLog.shared.changes.listen((_) => _schedule());
  }
  final AppState state;
  StreamSubscription<void>? _logs;
  Timer? _pending;
  Object? _lastSignature;
  void _schedule() {
    // Bursts of debugPrint must not rebuild the whole console for every line.
    _pending ??= Timer(const Duration(milliseconds: 100), () {
      _pending = null;
      final console = state.developerConsole;
      final signature = (
        enabled,
        busy,
        console.entries.lastOrNull,
        console.entries.length,
        AppLog.shared.revision,
        state.themeMode,
        state.accentSeed,
        state.fontPreferences,
        state.language,
      );
      if (_lastSignature == signature) return;
      _lastSignature = signature;
      notifyListeners();
    });
  }

  @override
  bool get enabled => state.developerConsoleEnabled;
  @override
  bool get busy => state.developerConsole.busy;
  @override
  List<ConsoleEntry> get entries => state.developerConsole.entries;
  @override
  List<String> get history => state.developerConsole.history;
  @override
  String get logs => AppLog.shared.snapshot();
  @override
  Future<void> execute(String input) => state.developerConsole.execute(input);
  @override
  Future<void> clearLogs() async => AppLog.shared.clear();
  @override
  Future<String> report() async => diagnosticReport(state);
  @override
  void dispose() {
    _pending?.cancel();
    _logs?.cancel();
    state.removeListener(_schedule);
    state.developerConsole.removeListener(_schedule);
    super.dispose();
  }
}
