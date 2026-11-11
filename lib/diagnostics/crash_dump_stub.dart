import '../state/app_state.dart';

Future<void> writeCrashDump(
  AppState? state,
  Object error,
  StackTrace stack, {
  String phase = 'uncaught',
}) async {}
