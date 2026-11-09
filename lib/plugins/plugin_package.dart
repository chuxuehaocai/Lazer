// i18n:data — validation messages are interface keys shown by the plugin UI
// through `context.tr`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'plugin_manifest.dart';

const maxPluginArchiveBytes = 16 * 1024 * 1024;

class PluginPackage {
  const PluginPackage(this.manifest, this.files, this.sources);
  final PluginManifest manifest;
  final Map<String, Uint8List> files;
  final Map<String, String> sources;
}

/// Decode, verify and validate away from the UI isolate before any installation.
PluginPackage decodePluginPackage(Uint8List bytes) {
  if (bytes.length > maxPluginArchiveBytes) {
    throw const FormatException('插件包不能超过 16 MB。');
  }
  final archive = _openPluginZip(bytes);
  final raw = <String, Uint8List>{};
  for (final file in archive) {
    if (!file.isFile || file.isSymbolicLink) continue;
    final name = _pluginZipName(file.name);
    if (name == null) continue;
    final content = file.content;
    raw[name] = content;
  }
  final files = _hoistPluginRoot(raw);
  if (files.length > 256) throw const FormatException('插件文件过多。');
  final names = <String>{};
  var total = 0;
  for (final entry in files.entries) {
    final name = entry.key;
    if (!PluginManifest.safePath(name) || !names.add(name.toLowerCase())) {
      throw const FormatException('插件包含不安全或重复的文件路径。');
    }
    total += entry.value.length;
    if (total > 8 * 1024 * 1024 || entry.value.length > 2 * 1024 * 1024) {
      throw const FormatException('插件解压后体积过大。');
    }
    if (name != 'manifest.json' &&
        !name.endsWith('.lua') &&
        !name.endsWith('.md') &&
        !name.endsWith('.txt') &&
        !name.endsWith('.json') &&
        name != 'LICENSE') {
      throw const FormatException('插件仅支持 Lua 源码与说明文件。');
    }
  }
  final manifestBytes = files['manifest.json'];
  if (manifestBytes == null) {
    throw const FormatException('ZIP 根目录缺少 manifest.json。');
  }
  final manifest = PluginManifest.decode(utf8.decode(manifestBytes));
  if (!files.containsKey(manifest.entry)) {
    throw const FormatException('缺少插件入口。');
  }
  return PluginPackage(manifest, files, {
    for (final entry in files.entries)
      if (entry.key.endsWith('.lua')) entry.key: utf8.decode(entry.value),
  });
}

Archive _openPluginZip(Uint8List bytes) {
  Object? first;
  try {
    return ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (error) {
    first = error;
  }
  try {
    return ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw FormatException('无法识别这个 ZIP。$first');
  }
}

/// Windows 资源管理器会把路径写成反斜杠，打包整个文件夹时入口也不在根上。
String? _pluginZipName(String raw) {
  var name = raw.replaceAll('\\', '/').trim();
  while (name.startsWith('./')) {
    name = name.substring(2);
  }
  while (name.startsWith('/')) {
    name = name.substring(1);
  }
  if (name.isEmpty || name.endsWith('/')) return null;
  final lower = name.toLowerCase();
  if (lower.startsWith('__macosx/') ||
      lower == '.ds_store' ||
      lower.endsWith('/.ds_store') ||
      lower == 'thumbs.db' ||
      lower.endsWith('/thumbs.db')) {
    return null;
  }
  return name;
}

Map<String, Uint8List> _hoistPluginRoot(Map<String, Uint8List> files) {
  if (files.containsKey('manifest.json') || files.isEmpty) return files;
  final roots = <String>{};
  for (final name in files.keys) {
    final slash = name.indexOf('/');
    if (slash <= 0) return files;
    roots.add(name.substring(0, slash));
    if (roots.length > 1) return files;
  }
  final prefix = '${roots.single}/';
  return {
    for (final entry in files.entries)
      entry.key.substring(prefix.length): entry.value,
  };
}
