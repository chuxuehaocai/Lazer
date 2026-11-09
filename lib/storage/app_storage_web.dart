import 'dart:io' show Directory;

import 'package:shared_preferences/shared_preferences.dart';

Future<Directory> appSupportDirectory() =>
    throw UnsupportedError('浏览器没有文件系统');
Future<Directory> appCacheDirectory() =>
    throw UnsupportedError('浏览器没有文件系统');
Future<Directory> appDocumentsDirectory() =>
    throw UnsupportedError('浏览器没有文件系统');

/// The browser keeps no application data directory; preferences live in
/// localStorage, so the storage migration is a no-op.
class AppStorage {
  AppStorage({
    bool? supported,
    Object? support,
    Object? cache,
    Object? documents,
  });

  static final shared = AppStorage();
  static const rootKey = 'lazer_data_root';
  static const pendingKey = 'lazer_pending_data_root';
  static const pendingAttemptsKey = 'lazer_pending_data_root_attempts';
  static const maxPendingAttempts = 3;

  final bool supported = false;
  String? error;
  String? get requestedRoot => null;
  bool get requiresRestart => false;
  bool get usingDefaultFallback => false;

  Future<Directory> supportDirectory() =>
      throw UnsupportedError('浏览器没有文件系统');
  Future<Directory> cacheDirectory() =>
      throw UnsupportedError('浏览器没有文件系统');
  Future<Directory> documentsDirectory() =>
      throw UnsupportedError('浏览器没有文件系统');

  Future<void> initialize(SharedPreferences prefs) async {}

  Future<void> schedule(String? root) async {}
}
