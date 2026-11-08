import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Directory> appSupportDirectory() => AppStorage.shared.supportDirectory();
Future<Directory> appCacheDirectory() => AppStorage.shared.cacheDirectory();
Future<Directory> appDocumentsDirectory() =>
    AppStorage.shared.documentsDirectory();

/// Directory changes are applied before any caches or decoders open files.
class AppStorage {
  AppStorage({
    bool? supported,
    Future<Directory> Function()? support,
    Future<Directory> Function()? cache,
    Future<Directory> Function()? documents,
  }) : supported = supported ?? Platform.isAndroid,
       _support = support ?? getApplicationSupportDirectory,
       _cache = cache ?? getApplicationCacheDirectory,
       _documents = documents ?? getApplicationDocumentsDirectory;

  static final shared = AppStorage();
  static const rootKey = 'lazer_data_root';
  static const pendingKey = 'lazer_pending_data_root';

  /// How many launches have already tried to apply [pendingKey].
  ///
  /// A migration that can never succeed (a folder that stays unwritable) used to
  /// be retried on every launch forever. After a bounded number of attempts the
  /// request is dropped and the settings page keeps showing the failure.
  static const pendingAttemptsKey = 'lazer_pending_data_root_attempts';
  static const maxPendingAttempts = 3;
  static const _marker = '.lazer-storage';
  final bool supported;
  final Future<Directory> Function() _support, _cache, _documents;
  String? _root, _pending;
  bool _hasPending = false;
  bool _fallback = false;
  String? error;
  String? get requestedRoot => _hasPending ? _pending : _root;
  bool get requiresRestart => _hasPending;
  bool get usingDefaultFallback => _fallback;

  Future<Directory> supportDirectory() => _directory('support', _support);
  Future<Directory> cacheDirectory() => _directory('cache', _cache);
  Future<Directory> documentsDirectory() => _directory('documents', _documents);

  Future<Directory> _directory(
    String name,
    Future<Directory> Function() fallback,
  ) => !supported || _root == null || _fallback
      ? fallback()
      : Directory('$_root/$name').create(recursive: true);

  Future<void> initialize(SharedPreferences prefs) async {
    if (!supported) return;
    _root = _normalize(prefs.getString(rootKey));
    _hasPending = prefs.containsKey(pendingKey);
    _pending = _normalize(prefs.getString(pendingKey));
    _fallback = false;
    var rootAvailable = _root == null;
    try {
      if (_root != null) {
        await _verifyWritable(Directory('$_root/support'));
        rootAvailable = true;
      }
      if (!_hasPending) return;
      final old = [
        await supportDirectory(),
        await cacheDirectory(),
        await documentsDirectory(),
      ];
      final next = _pending;
      final target = next == null
          ? [await _support(), await _cache(), await _documents()]
          : [
              Directory('$next/support'),
              Directory('$next/cache'),
              Directory('$next/documents'),
            ];
      final mapping = {
        for (var i = 0; i < old.length; i++)
          _path(old[i].path): _path(target[i].path),
      };
      // Keep old files intact until every copy and preference update succeeds.
      for (var i = 0; i < old.length; i++) {
        await _copy(old[i], target[i], mapping);
      }
      for (final key in prefs.getKeys().toList()) {
        final value = prefs.get(key);
        if (value is String && key != rootKey && key != pendingKey) {
          final rewritten = _rewriteString(value, mapping);
          if (rewritten != value) await prefs.setString(key, rewritten);
        }
      }
      if (next == null) {
        await prefs.remove(rootKey);
      } else {
        await prefs.setString(rootKey, next);
      }
      await prefs.remove(pendingKey);
      await prefs.remove(pendingAttemptsKey);
      _root = next;
      _pending = null;
      _hasPending = false;
      error = null;
    } catch (failure) {
      error = failure.toString();
      _fallback = !rootAvailable;
      final int attempts = (prefs.getInt(pendingAttemptsKey) ?? 0) + 1;
      if (attempts >= maxPendingAttempts) {
        // Give up on a request that keeps failing (unwritable folder, revoked
        // permission) instead of retrying it on every launch. The error and the
        // fallback stay visible in the storage settings.
        await prefs.remove(pendingKey);
        await prefs.remove(pendingAttemptsKey);
        _pending = null;
        _hasPending = false;
      } else {
        await prefs.setInt(pendingAttemptsKey, attempts);
      }
    }
  }

  Future<void> schedule(String? path) async {
    if (!supported) {
      throw UnsupportedError('Custom data storage requires Android');
    }
    if (path != null &&
        path.trim().isNotEmpty &&
        !Uri.directory(
          path.trim(),
          windows: Platform.isWindows,
        ).hasAbsolutePath) {
      throw const FormatException('Choose an absolute filesystem path');
    }
    var next = _normalize(path);
    if (next != null) {
      final uri = Uri.file(next, windows: Platform.isWindows);
      if (!uri.hasAbsolutePath || uri.scheme != 'file') {
        throw const FormatException('Choose an absolute filesystem path');
      }
      final directory = Directory(next).absolute;
      for (final current in [
        await supportDirectory(),
        await cacheDirectory(),
        await documentsDirectory(),
      ]) {
        final original = _path(current.path);
        if (directory.path == original ||
            directory.path.startsWith('$original${Platform.pathSeparator}')) {
          throw const FormatException(
            'Choose a folder outside the current data directories',
          );
        }
      }
      await directory.create(recursive: true);
      final resolved = _path(await directory.resolveSymbolicLinks());
      for (final current in [
        await supportDirectory(),
        await cacheDirectory(),
        await documentsDirectory(),
      ]) {
        final original = await current.exists()
            ? _path(await current.resolveSymbolicLinks())
            : _path(current.path);
        if (resolved == original ||
            resolved.startsWith('$original${Platform.pathSeparator}')) {
          throw const FormatException('Data destination overlaps its source');
        }
      }
      next = resolved;
      final marker = File('${directory.path}/$_marker');
      if (!await marker.exists()) {
        for (final name in ['support', 'cache', 'documents']) {
          if (await Directory('${directory.path}/$name').exists()) {
            throw const FormatException(
              'Choose an empty folder for Lazer data',
            );
          }
        }
      }
      await _verifyWritable(directory);
      await marker.writeAsString('Lazer data directory v1');
    }
    final prefs = await SharedPreferences.getInstance();
    if (next == _root) {
      await prefs.remove(pendingKey);
      _hasPending = false;
    } else {
      await prefs.setString(pendingKey, next ?? '');
      // A fresh request gets a fresh retry budget.
      await prefs.remove(pendingAttemptsKey);
      _hasPending = true;
    }
    _pending = next;
    error = null;
  }

  static String? _normalize(String? value) =>
      value == null || value.trim().isEmpty ? null : _path(value.trim());

  static Future<void> _verifyWritable(Directory directory) async {
    await directory.create(recursive: true);
    final probe = File(
      '${directory.path}/.lazer-write-${DateTime.now().microsecondsSinceEpoch}',
    );
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
  }

  static String _path(String value) {
    var result = File(value).absolute.uri.normalizePath().toFilePath();
    while (result.endsWith(Platform.pathSeparator) &&
        Directory(result).parent.path != result) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static Future<void> _copy(
    Directory source,
    Directory target,
    Map<String, String> mapping,
  ) async {
    if (_path(source.path) == _path(target.path) || !await source.exists()) {
      return;
    }
    if (_path(
      target.path,
    ).startsWith('${_path(source.path)}${Platform.pathSeparator}')) {
      throw const FormatException('Data destination overlaps its source');
    }
    await target.create(recursive: true);
    await for (final entry in source.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      final destination = '${target.path}/$name';
      if (entry is Directory) {
        await _copy(entry, Directory(destination), mapping);
      } else if (entry is File) {
        if (name.endsWith('.json')) {
          try {
            final text = await entry.readAsString();
            await File(
              destination,
            ).writeAsString(_rewriteString(text, mapping), flush: true);
          } on FormatException {
            await entry.copy(destination);
          }
        } else {
          await entry.copy(destination);
        }
      }
    }
  }

  static String _rewriteString(String value, Map<String, String> mapping) {
    final candidate =
        Platform.isWindows && RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value)
        ? _path(value)
        : value;
    for (final entry in mapping.entries) {
      for (final pair in [
        (entry.key, entry.value),
        (
          Directory(entry.key).uri.toString(),
          Directory(entry.value).uri.toString(),
        ),
      ]) {
        final from = pair.$1;
        if (candidate == from ||
            candidate.startsWith(
              from.endsWith('/') ? from : '$from${Platform.pathSeparator}',
            )) {
          return '${pair.$2}${candidate.substring(from.length)}';
        }
      }
    }
    Object? rewrite(Object? object) => switch (object) {
      String() => _rewriteString(object, mapping),
      List() => object.map(rewrite).toList(),
      Map() => object.map((key, item) => MapEntry(key, rewrite(item))),
      _ => object,
    };
    if (!value.startsWith('{') && !value.startsWith('[')) return value;
    try {
      return jsonEncode(rewrite(jsonDecode(value)));
    } catch (_) {
      return value;
    }
  }
}
