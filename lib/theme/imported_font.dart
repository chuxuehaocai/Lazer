import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_selector/file_selector.dart' show XFile;
import '../storage/app_storage.dart';

import 'font_preferences.dart';

/// Imported faces are copied into app storage so moving the original file does
/// not break the preference. A content-specific family also allows replacement
/// without Flutter reusing the previously loaded font.
abstract final class ImportedFont {
  static final ImportedFontSession _session = ImportedFontSession();
  static const int maximumFileBytes = 64 * 1024 * 1024;

  static void checkFileSize(int length) {
    if (length > maximumFileBytes) {
      throw const FontImportException(FontImportFailure.tooLarge);
    }
  }

  /// Read at most the stat'ed length, even if the file grows while selected.
  static Future<Uint8List> readFile(String path, {int? maximumLength}) async {
    final file = File(path);
    final length = await file.length();
    checkFileSize(length);
    if (maximumLength != null && length > maximumLength) {
      throw const FormatException('Font file changed while importing');
    }
    final handle = await file.open();
    try {
      final buffer = Uint8List(length);
      var offset = 0;
      while (offset < length) {
        final count = await handle.readInto(buffer, offset, length);
        if (count == 0) break;
        offset += count;
      }
      final bytes = Uint8List.sublistView(buffer, 0, offset);
      checkFileSize(bytes.length);
      return bytes;
    } finally {
      await handle.close();
    }
  }

  /// file_selector returns a lazy XFile. Prefer the local path so a huge file
  /// never enters memory; browser/in-memory selections retain a checked fallback.
  static Future<Uint8List> readSelection(
    XFile file, {
    int? maximumLength,
  }) async {
    if (!kIsWeb && file.path.isNotEmpty) {
      return readFile(file.path, maximumLength: maximumLength);
    }
    final length = await file.length();
    checkFileSize(length);
    if (maximumLength != null && length > maximumLength) {
      throw const FormatException('Font file changed while importing');
    }
    final bytes = await file.readAsBytes();
    checkFileSize(bytes.length);
    return bytes;
  }

  static Future<FontFamilyPreference> importFile(
    Uint8List bytes,
    String name, {
    Directory? storageDirectory,
  }) async {
    return _importBytes(bytes, name, storageDirectory: storageDirectory);
  }

  static Future<FontFamilyPreference> importSelection(XFile file) async {
    final length = await file.length();
    checkFileSize(length);
    // Streaming identity allows an already loaded font to be reused even when
    // the byte budget is full, without allocating another whole font buffer.
    final digest = await sha256.bind(file.openRead(0, length)).first;
    final family = 'LazerImported_$digest';
    final existing = await _session._reuse(family);
    if (existing != null) return existing;
    _session.checkCapacity(family);
    final reservation = _session._reserve(length);
    try {
      final bytes = await readSelection(file, maximumLength: length);
      return await _importBytes(bytes, file.name, reservation: reservation);
    } finally {
      reservation.releaseTemporary();
    }
  }

  static Future<FontFamilyPreference> _importBytes(
    Uint8List bytes,
    String name, {
    Directory? storageDirectory,
    _FontReservation? reservation,
  }) async {
    validate(bytes);
    final digest = sha256.convert(bytes).toString();
    final family = 'LazerImported_$digest';
    final existing = await _session._reuse(family);
    if (existing != null) return existing;
    _session._checkCapacity(family, reservation);
    final reserved = reservation ?? _session._reserve(bytes.length);
    try {
      final directory =
          storageDirectory ??
          Directory(
            '${(await appSupportDirectory()).path}'
            '${Platform.pathSeparator}fonts',
          );
      await directory.create(recursive: true);
      final extension = name.toLowerCase().endsWith('.otf') ? 'otf' : 'ttf';
      final file = File(
        '${directory.path}${Platform.pathSeparator}$digest.$extension',
      );
      if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
      final preference = FontFamilyPreference(
        source: FontSource.imported,
        name: name,
        path: file.path,
        family: 'LazerImported_$digest',
      );
      await _session._load(preference, bytes: bytes, reservation: reserved);
      return preference;
    } finally {
      reserved.releaseTemporary();
    }
  }

  static void validate(Uint8List bytes) {
    checkFileSize(bytes.length);
    const invalid = FormatException('请选择有效的 OTF 或 TTF 字体文件');
    if (bytes.length < 12) throw invalid;
    final data = ByteData.sublistView(bytes);
    final signature = data.getUint32(0);
    if (signature != 0x00010000 &&
        signature != 0x4F54544F &&
        signature != 0x74727565) {
      throw invalid;
    }
    final tables = data.getUint16(4);
    if (tables == 0 || bytes.length < 12 + tables * 16) throw invalid;
    for (var index = 0; index < tables; index++) {
      final offset = data.getUint32(12 + index * 16 + 8);
      final length = data.getUint32(12 + index * 16 + 12);
      if (offset + length > bytes.length) throw invalid;
    }
  }

  static Future<void> load(FontFamilyPreference preference) =>
      _session.load(preference);
}

enum FontImportFailure { tooLarge, sessionLimit }

class FontImportException implements Exception {
  const FontImportException(this.failure);
  final FontImportFailure failure;
  @override
  String toString() => 'FontImportException(${failure.name})';
}

/// A bounded registry for one Flutter engine. Registered families cannot be
/// unloaded, so both completed and in-flight registrations consume a slot.
class ImportedFontSession {
  ImportedFontSession({Future<void> Function(String, Uint8List)? register})
    : _register = register ?? _registerFont;

  static const int maximumFamilies = 8;
  static const int maximumSessionBytes = 64 * 1024 * 1024;
  int _reservedBytes = 0;
  int _preparations = 0;
  final Map<String, FontFamilyPreference> _preferences = {};
  final Future<void> Function(String, Uint8List) _register;
  final Map<String, Future<void>> _loads = {};

  void checkCapacity(String family) {
    _checkCapacity(family);
  }

  void _checkCapacity(String family, [_FontReservation? reservation]) {
    final ownPreparation = reservation?.preparing == true ? 1 : 0;
    if (!_loads.containsKey(family) &&
        _loads.length + _preparations - ownPreparation >= maximumFamilies) {
      throw const FontImportException(FontImportFailure.sessionLimit);
    }
  }

  _FontReservation _reserve(int bytes, {bool familyCounted = false}) {
    ImportedFont.checkFileSize(bytes);
    if (_reservedBytes + bytes > maximumSessionBytes ||
        (!familyCounted && _loads.length + _preparations >= maximumFamilies)) {
      throw const FontImportException(FontImportFailure.sessionLimit);
    }
    _reservedBytes += bytes;
    if (!familyCounted) _preparations++;
    return _FontReservation(this, bytes, preparing: !familyCounted);
  }

  Future<FontFamilyPreference?> _reuse(String family) async {
    final loaded = _loads[family];
    if (loaded == null) return null;
    await loaded;
    return _preferences[family];
  }

  Future<void> load(FontFamilyPreference preference, {Uint8List? bytes}) =>
      _load(preference, bytes: bytes);

  Future<void> _load(
    FontFamilyPreference preference, {
    Uint8List? bytes,
    _FontReservation? reservation,
  }) {
    if (preference.source != FontSource.imported) return Future.value();
    final family = preference.family;
    if (family == null || preference.path == null) {
      return Future.error(const FormatException('导入字体不存在，请重新导入'));
    }
    final existing = _loads[family];
    if (existing != null) return existing;
    try {
      _checkCapacity(family, reservation);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    reservation?.adopt();
    return _loads.putIfAbsent(
      family,
      () => Future<void>.microtask(() async {
        _FontReservation? reserved = reservation;
        try {
          final length = bytes?.length ?? await File(preference.path!).length();
          ImportedFont.checkFileSize(length);
          reserved ??= _reserve(length, familyCounted: true);
          final data =
              bytes ??
              await ImportedFont.readFile(
                preference.path!,
                maximumLength: length,
              );
          ImportedFont.validate(data);
          await _register(family, data);
          _preferences[family] = preference;
          reserved.committed = true;
        } catch (_) {
          reserved?.releaseTemporary();
          _loads.remove(family);
          rethrow;
        }
      }),
    );
  }

  static Future<void> _registerFont(String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

class _FontReservation {
  _FontReservation(this.owner, this.bytes, {required this.preparing});
  final ImportedFontSession owner;
  final int bytes;
  bool committed = false;
  bool preparing;
  bool _released = false;
  void releaseTemporary() {
    if (_released || committed) return;
    _released = true;
    adopt();
    owner._reservedBytes -= bytes;
  }

  void adopt() {
    if (!preparing) return;
    preparing = false;
    owner._preparations--;
  }
}
