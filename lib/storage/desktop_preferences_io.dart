import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

DesktopPreferencesStore? _installed;

/// Replaces the stock preference store where it blocks the UI isolate.
///
/// `shared_preferences` on Windows and Linux keeps every value in one JSON
/// file and, on each `set`/`remove`, encodes all of them and rewrites that file
/// with synchronous I/O on the calling isolate. The file also holds the saved
/// playback queue, so a track change or a settings slider stalled frames for as
/// long as the whole snapshot took to encode and reach the disk. Must run
/// before the first `SharedPreferences.getInstance()`.
void installDesktopPreferences() {
  if (_installed != null || !(Platform.isWindows || Platform.isLinux)) return;
  SharedPreferencesStorePlatform.instance = _installed =
      DesktopPreferencesStore();
}

Future<void> flushDesktopPreferences() =>
    _installed?.flush() ?? Future<void>.value();

/// The stock desktop store's file and format, written off the UI isolate.
///
/// Changes update memory at once and share asynchronous writes: a burst costs
/// one write for its first change and one more for everything that arrived
/// meanwhile. Each write replaces the file atomically, so a crash leaves the
/// previous complete snapshot instead of a truncated one, and a value that is
/// already stored is not written again. A setter's future still completes only
/// after its value is on disk.
class DesktopPreferencesStore extends SharedPreferencesStorePlatform {
  DesktopPreferencesStore({Future<File?> Function()? file})
    : _file = file ?? _defaultFile;

  static const String _defaultPrefix = 'flutter.';
  static const int _largeSnapshotCharacters = 65536;

  final Future<File?> Function() _file;
  Map<String, Object>? _values;
  Future<Map<String, Object>>? _loading;
  Future<void>? _writing;
  bool _dirty = false;
  bool _stored = true;
  bool _detached = false;
  int _writes = 0;

  @visibleForTesting
  int get debugWrites => _writes;

  static File? _defaultTarget;
  static Future<File?> _defaultFile() async => _defaultTarget ??= File(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'shared_preferences.json',
    ),
  );

  Future<Map<String, Object>> _read() => _loading ??= _load().then(
    (Map<String, Object> values) => _values = values,
  );

  Future<Map<String, Object>> _load() async {
    final File file;
    final String text;
    try {
      final File? located = await _file();
      if (located == null) throw const FileSystemException('No data folder');
      file = located;
      if (!await file.exists()) return <String, Object>{};
      text = await file.readAsString();
    } catch (error) {
      // Run on defaults, as the stock store does without a data folder, but
      // never replace settings that could not be read with those defaults.
      _detached = true;
      debugPrint('Preferences could not be read: $error');
      return <String, Object>{};
    }
    if (text.isEmpty) return <String, Object>{};
    try {
      final Object? data = json.decode(text);
      if (data is Map) {
        return <String, Object>{
          for (final MapEntry<Object?, Object?> entry in data.entries)
            if (entry.key is String && entry.value != null)
              entry.key! as String: entry.value!,
        };
      }
    } on FormatException {
      // Handled below with every other unusable snapshot.
    }
    try {
      await file.rename('${file.path}.corrupt');
    } catch (_) {}
    return <String, Object>{};
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    final Object stored = value is List<String>
        ? List<String>.of(value)
        : value;
    return _update((Map<String, Object> values) {
      final bool changed = !_same(values[key], stored);
      values[key] = stored;
      return changed;
    });
  }

  @override
  Future<bool> remove(String key) =>
      _update((Map<String, Object> values) => values.remove(key) != null);

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    final PreferencesFilter filter = parameters.filter;
    return _update((Map<String, Object> values) {
      final int before = values.length;
      values.removeWhere(
        (String key, _) =>
            key.startsWith(filter.prefix) &&
            (filter.allowList?.contains(key) ?? true),
      );
      return values.length != before;
    });
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final PreferencesFilter filter = parameters.filter;
    return <String, Object>{
      for (final MapEntry<String, Object> entry in (await _read()).entries)
        if (entry.key.startsWith(filter.prefix) &&
            (filter.allowList?.contains(entry.key) ?? true))
          entry.key: entry.value,
    };
  }

  Future<void> flush() async {
    await _loading;
    await _writing;
  }

  Future<bool> _update(bool Function(Map<String, Object> values) change) {
    final Map<String, Object>? values = _values;
    if (values != null) return _commit(change(values));
    return _read().then(
      (Map<String, Object> values) => _commit(change(values)),
    );
  }

  Future<bool> _commit(bool changed) async {
    if (changed || !_stored) {
      _dirty = true;
      await (_writing ??= _drain());
    } else {
      await _writing;
    }
    return _stored;
  }

  Future<void> _drain() async {
    try {
      await null;
      while (_dirty) {
        _dirty = false;
        _stored = await _write();
      }
    } finally {
      _writing = null;
    }
  }

  Future<bool> _write() async {
    try {
      if (_detached) return false;
      final File? file = await _file();
      final Map<String, Object>? values = _values;
      if (file == null || values == null) return false;
      final List<int> bytes = _isLarge(values)
          ? await compute(
              _encode,
              Map<String, Object>.of(values),
              debugLabel: 'preferences-write',
            )
          : _encode(values);
      await file.parent.create(recursive: true);
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        // Windows refuses the replace while another process holds the target
        // open; fall back to the stock store's in-place write.
        await file.writeAsBytes(bytes, flush: true);
        try {
          await temporary.delete();
        } catch (_) {}
      }
      _writes++;
      return true;
    } catch (error) {
      debugPrint('Preferences could not be saved: $error');
      return false;
    }
  }

  static bool _isLarge(Map<String, Object> values) {
    var characters = 0;
    for (final Object value in values.values) {
      if (value is String) {
        characters += value.length;
      } else if (value is List) {
        for (final Object? item in value) {
          if (item is String) characters += item.length;
        }
      }
      if (characters >= _largeSnapshotCharacters) return true;
    }
    return false;
  }

  static bool _same(Object? stored, Object value) {
    if (stored is List && value is List) {
      return listEquals<Object?>(stored, value);
    }
    return stored.runtimeType == value.runtimeType && stored == value;
  }
}

List<int> _encode(Map<String, Object> values) =>
    utf8.encode(json.encode(values));
