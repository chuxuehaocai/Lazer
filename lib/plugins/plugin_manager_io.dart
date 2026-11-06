import '../state/build_safe_notifier.dart';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../storage/app_storage.dart';
import '../gateway/lua_music_gateway.dart';
import '../gateway/music_gateway.dart';
import 'lua_plugin_runtime.dart';
import 'plugin_manifest.dart';

class InstalledPlugin {
  InstalledPlugin(
    this.manifest, {
    required this.enabled,
    this.runtime,
    this.error,
  });
  final PluginManifest manifest;
  bool enabled;
  LuaPluginRuntime? runtime;
  final List<LuaMusicGateway> gateways = [];
  MusicGateway? get gateway => gateways.firstOrNull;

  String? error;
}

class PluginManager extends ChangeNotifier with BuildSafeNotifier {
  PluginManager({this.rootDirectory});
  Directory? rootDirectory;
  final List<InstalledPlugin> _plugins = [];
  List<InstalledPlugin> get plugins => List.unmodifiable(_plugins);
  List<MusicGateway> get gateways => [
    for (final plugin in _plugins)
      if (plugin.enabled && plugin.runtime != null) ...plugin.gateways,
  ];
  bool busy = false;
  bool _disposed = false;
  Future<void>? _restoring;

  /// Stop owned playback and detach gateways before shutting down a VM.
  Future<void> Function(String pluginId)? beforeChange;
  Future<void> Function()? afterChange;

  Future<Directory> get root async => rootDirectory ??= Directory(
    p.join((await AppStorage.shared.supportDirectory()).path, 'lua_plugins'),
  );

  Future<void> restore() => _restoring ??= _restore();
  Future<void> _restore() async {
    try {
      final directory = await (await root).create(recursive: true);
      await for (final item in directory.list(followLinks: false)) {
        if (item is! Directory || p.basename(item.path).startsWith('.')) {
          continue;
        }
        try {
          final manifest = PluginManifest.decode(
            await File(p.join(item.path, 'manifest.json')).readAsString(),
          );
          if (p.basename(item.path) != manifest.id) continue;
          final disabled = await File(p.join(item.path, '.disabled')).exists();
          final plugin = InstalledPlugin(manifest, enabled: !disabled);
          _plugins.add(plugin);
          if (!disabled) await _start(plugin);
        } catch (_) {
          /* Ignore incomplete staging directories. */
        }
      }
    } catch (_) {
      // Plugin storage may be unavailable in a sandboxed test or web build.
    }
    _notify();
  }

  Future<void> _start(InstalledPlugin plugin) async {
    try {
      final sources = <String, String>{};
      final directory = Directory(
        p.join((await root).path, plugin.manifest.id),
      );
      var total = 0;
      await for (final file in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (file is! File || !file.path.endsWith('.lua')) continue;
        total += await file.length();
        if (total > 8 * 1024 * 1024) throw const FormatException();
        sources[p
            .relative(file.path, from: directory.path)
            .replaceAll('\\', '/')] = await file
            .readAsString();
      }
      final runtime = LuaPluginRuntime(
        manifest: plugin.manifest,
        sources: sources,
        dataDirectory: p.join(
          (await root).parent.path,
          'lua_plugin_data',
          plugin.manifest.id,
        ),
      );
      plugin.runtime = runtime;
      await runtime.start();
      final description = await runtime.invoke('describe');
      final declared = description is Map ? description['providers'] : null;
      final providers = declared is List
          ? declared.whereType<Map>().toList()
          : [
              {
                'id': plugin.manifest.provider,
                'name': plugin.manifest.name,
                'capabilities': plugin.manifest.capabilities,
                'auth': plugin.manifest.auth,
              },
            ];
      plugin.gateways.clear();
      final identities = <String>{};
      for (final descriptor in providers) {
        final providerId = descriptor['id'] as String? ?? '';
        final name = descriptor['name'] as String? ?? '';
        if (!RegExp(r'^[a-z][a-z0-9_-]{1,39}$').hasMatch(providerId) ||
            providerId == 'local' ||
            name.trim().isEmpty ||
            !identities.add(providerId)) {
          throw const FormatException('Invalid Lua platform description');
        }
        plugin.gateways.add(
          LuaMusicGateway(
            runtime: runtime,
            pluginId: plugin.manifest.id,
            provider: MusicProvider(
              id: providerId,
              name: name,
              experimental: descriptor['experimental'] == true,
            ),
            connectionId: plugin.manifest.id,
            authenticationMethods: Set<String>.from(
              descriptor['auth'] is List
                  ? descriptor['auth'] as List
                  : const [],
            ),
            loginHint: descriptor['loginHint'] as String?,
            cookieHint: descriptor['cookieHint'] as String?,
            forgotPasswordUrl: descriptor['forgotPasswordUrl'] as String?,
            declaredCapabilities: {
              for (final name
                  in descriptor['capabilities'] is List
                      ? descriptor['capabilities'] as List
                      : const [])
                for (final capability in MusicCapability.values)
                  if (capability.name == name) capability,
            },
          ),
        );
      }
      plugin.error = null;
    } catch (_) {
      plugin.runtime?.close();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.error = '插件启动失败，请检查插件版本或重新导入。';
    }
  }

  Future<InstalledPlugin> importZip(Uint8List bytes) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    busy = true;
    _notify();
    Directory? staging;
    try {
      await restore();
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
      final base = (await root).absolute;
      staging = await Directory(
        p.join(base.path, '.staging-${DateTime.now().microsecondsSinceEpoch}'),
      ).create();
      for (final file in archive.where((f) => f.isFile)) {
        final destination = File(
          p.join(staging.path, file.name.replaceAll('/', p.separator)),
        );
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(file.content);
      }
      // Compile and initialize before touching the installed version or its data.
      final sourceMap = <String, String>{
        for (final f in archive.where(
          (f) => f.isFile && f.name.endsWith('.lua'),
        ))
          f.name: utf8.decode(f.content),
      };
      final probe = LuaPluginRuntime(
        manifest: manifest,
        sources: sourceMap,
        dataDirectory: p.join(staging.path, '.probe-data'),
      );
      try {
        await probe.start();
      } finally {
        probe.close();
      }
      final previous = _plugins
          .where((v) => v.manifest.id == manifest.id)
          .firstOrNull;
      final enabled = previous?.enabled ?? true;
      await beforeChange?.call(manifest.id);
      previous?.runtime?.close();
      final installed = Directory(p.join(base.path, manifest.id));
      final backup = Directory(p.join(base.path, '.backup-${manifest.id}'));
      if (await backup.exists()) await backup.delete(recursive: true);
      if (await installed.exists()) await installed.rename(backup.path);
      try {
        await staging.rename(installed.path);
        staging = null;
        if (!enabled) {
          await File(p.join(installed.path, '.disabled')).writeAsString('');
        }
        final plugin = InstalledPlugin(manifest, enabled: enabled);
        _plugins.removeWhere((v) => v.manifest.id == manifest.id);
        _plugins.add(plugin);
        if (enabled) {
          await _start(plugin);
          if (plugin.error != null) {
            throw const PluginException('新插件无法启动，已保留旧版本。');
          }
        }
        await afterChange?.call();
        if (await backup.exists()) await backup.delete(recursive: true);
        return plugin;
      } catch (_) {
        _plugins
            .where((v) => v.manifest.id == manifest.id)
            .firstOrNull
            ?.runtime
            ?.close();
        _plugins.removeWhere((v) => v.manifest.id == manifest.id);
        if (await installed.exists()) await installed.delete(recursive: true);
        if (await backup.exists()) await backup.rename(installed.path);
        if (previous != null) {
          _plugins.removeWhere((v) => v.manifest.id == manifest.id);
          _plugins.add(previous);
          if (previous.enabled) await _start(previous);
        }
        await afterChange?.call();
        rethrow;
      }
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      busy = false;
      _notify();
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((v) => v.manifest.id == id);
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      plugin.runtime?.close();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.enabled = enabled;
      final marker = File(p.join((await root).path, id, '.disabled'));
      if (enabled) {
        if (await marker.exists()) await marker.delete();
        await _start(plugin);
      } else {
        await marker.writeAsString('');
        plugin.error = null;
      }
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> uninstall(String id) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((v) => v.manifest.id == id);
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      plugin.runtime?.close();
      plugin.gateways.clear();
      final base = (await root).absolute.path;
      final directory = Directory(p.join(base, plugin.manifest.id));
      if (p.dirname(directory.absolute.path) != base) {
        throw const FormatException();
      }
      if (await directory.exists()) await directory.delete(recursive: true);
      _plugins.remove(plugin);
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final plugin in _plugins) {
      plugin.runtime?.close();
    }
    super.dispose();
  }
}
