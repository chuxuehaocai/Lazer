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
  if (bytes.length > 16 * 1024 * 1024) {
    throw const FormatException('插件包不能超过 16 MB。');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  if (archive.length > 256) throw const FormatException('插件文件过多。');
  final names = <String>{};
  var total = 0;
  for (final file in archive) {
    final name = file.name.endsWith('/')
        ? file.name.substring(0, file.name.length - 1)
        : file.name;
    if (!PluginManifest.safePath(name) ||
        !names.add(name.toLowerCase()) ||
        file.isSymbolicLink) {
      throw const FormatException('插件包含不安全或重复的文件路径。');
    }
    total += file.size;
    if (total > 8 * 1024 * 1024 || file.size > 2 * 1024 * 1024) {
      throw const FormatException('插件解压后体积过大。');
    }
    if (file.isFile &&
        name != 'manifest.json' &&
        !name.endsWith('.lua') &&
        !name.endsWith('.md') &&
        !name.endsWith('.txt') &&
        !name.endsWith('.json') &&
        name != 'LICENSE') {
      throw const FormatException('插件仅支持 Lua 源码与说明文件。');
    }
  }
  final manifestFile = archive.findFile('manifest.json');
  if (manifestFile == null) {
    throw const FormatException('ZIP 根目录缺少 manifest.json。');
  }
  final manifest = PluginManifest.decode(utf8.decode(manifestFile.content));
  if (archive.findFile(manifest.entry) == null) {
    throw const FormatException('缺少插件入口。');
  }
  final files = <String, Uint8List>{
    for (final file in archive.where((file) => file.isFile))
      file.name: Uint8List.fromList(file.content),
  };
  return PluginPackage(manifest, files, {
    for (final file in files.entries)
      if (file.key.endsWith('.lua')) file.key: utf8.decode(file.value),
  });
}
