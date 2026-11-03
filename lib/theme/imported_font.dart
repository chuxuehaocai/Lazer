import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import '../storage/app_storage.dart';

import 'font_preferences.dart';

/// Imported faces are copied into app storage so moving the original file does
/// not break the preference. A content-specific family also allows replacement
/// without Flutter reusing the previously loaded font.
abstract final class ImportedFont {
  static final Set<String> _loaded = {};

  static Future<FontFamilyPreference> importFile(
    Uint8List bytes,
    String name, {
    Directory? storageDirectory,
  }) async {
    validate(bytes);
    final digest = sha256.convert(bytes).toString();
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
    await load(preference);
    return preference;
  }

  static void validate(Uint8List bytes) {
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

  static Future<void> load(FontFamilyPreference preference) async {
    if (preference.source != FontSource.imported) return;
    final family = preference.family;
    if (family == null || preference.path == null) {
      throw const FormatException('导入字体不存在，请重新导入');
    }
    if (_loaded.contains(family)) return;
    final bytes = await File(preference.path!).readAsBytes();
    validate(bytes);
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loaded.add(family);
  }
}
