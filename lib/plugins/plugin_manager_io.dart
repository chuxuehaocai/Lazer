// i18n:data — manager status and validation messages are interface keys shown
// by the plugin manager through `context.tr`.
import '../state/build_safe_notifier.dart';
import 'dart:convert';
import 'dart:io';

import 'plugin_package.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../storage/app_storage.dart';
import '../gateway/lua_music_gateway.dart';
import '../gateway/music_gateway.dart';
import '../utils/media_requests.dart';
import '../utils/system_http.dart';
import '../theme/lazer_theme.dart';
import '../ui/layout_system.dart';
import 'lua_plugin_runtime.dart';
import 'lua_theme_engine.dart';
import 'plugin_manifest.dart';
import 'plugin_extensions.dart';

class InstalledPlugin {
  InstalledPlugin(
    this.manifest, {
    required this.enabled,
    this.runtime,
    this.error,
  });
  final PluginManifest manifest;
  bool enabled;
  bool networkGranted = false;
  bool socketGranted = false;
  bool socketServerGranted = false;
  bool websocketGranted = false;
  bool websocketServerGranted = false;
  final Map<String, Object?> settingValues = <String, Object?>{};
  final List<LuaPluginSetting> settings = <LuaPluginSetting>[];
  final List<LuaPlayerMenuItem> playerMenuItems = <LuaPlayerMenuItem>[];
  LuaPluginRuntime? runtime;
  final List<LuaMusicGateway> gateways = [];
  LazerThemeTokens? theme;
  LazerLayoutDefinition? layout;
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
  List<LuaPluginSetting> get pluginSettings => [
    for (final plugin in _plugins)
      if (plugin.enabled && plugin.runtime != null) ...plugin.settings,
  ];
  List<LuaPlayerMenuItem> get playerMenuItems => [
    for (final plugin in _plugins)
      if (plugin.enabled && plugin.runtime != null) ...plugin.playerMenuItems,
  ];
  LazerThemeTokens? get activeTheme => _plugins
      .where((plugin) => plugin.enabled && plugin.runtime != null)
      .map((plugin) => plugin.theme)
      .whereType<LazerThemeTokens>()
      .firstOrNull;
  LazerLayoutDefinition? get activeLayout => _plugins
      .where((plugin) => plugin.enabled && plugin.runtime != null)
      .map((plugin) => plugin.layout)
      .whereType<LazerLayoutDefinition>()
      .firstOrNull;
  int get skinRevision => Object.hash(
    activeTheme?.toJson().toString(),
    activeLayout?.toJson().toString(),
  );
  bool busy = false;
  bool _disposed = false;
  Future<void>? _restoring;

  void notifyProxyUpdated({required ProxyMode mode, String? endpoint}) {
    for (final plugin in _plugins) {
      plugin.runtime?.updateProxy(mode: mode, endpoint: endpoint);
    }
  }

  /// Stop owned playback and detach gateways before shutting down a VM.
  Future<void> Function(String pluginId)? beforeChange;
  Future<void> Function()? afterChange;
  Future<bool> Function(InstalledPlugin plugin, String permission)?
  onPermissionRequest;

  Future<bool> _requestPermission(
    InstalledPlugin plugin,
    String permission,
  ) async {
    if (permission == 'network' && plugin.networkGranted) return true;
    if (permission == 'socket' && plugin.socketGranted) return true;
    if (permission == 'socketServer' && plugin.socketServerGranted) return true;
    if (permission == 'websocket' && plugin.websocketGranted) return true;
    if (permission == 'websocketServer' && plugin.websocketServerGranted) {
      return true;
    }
    if (onPermissionRequest == null) return false;
    bool granted;
    try {
      granted = await onPermissionRequest!(plugin, permission);
    } catch (_) {
      return false;
    }
    if (granted) {
      // The request originates inside this plugin's isolate. Restarting the
      // runtime here would wait for that isolate to finish the request while
      // it is waiting for this answer, so persist the grant in place. The
      // runtime updates its own capability after the reply; explicit toggles
      // still use the lifecycle-aware setters below.
      await _rememberPermission(plugin, permission);
    }
    return granted;
  }

  Future<void> _rememberPermission(
    InstalledPlugin plugin,
    String permission,
  ) async {
    final String? markerName = switch (permission) {
      'network' => '.network-enabled',
      'socket' => '.socket-enabled',
      'socketServer' => '.socket-server-enabled',
      'websocket' => '.websocket-enabled',
      'websocketServer' => '.websocket-server-enabled',
      _ => null,
    };
    if (markerName == null) return;
    switch (permission) {
      case 'network':
        plugin.networkGranted = true;
      case 'socket':
        plugin.socketGranted = true;
      case 'socketServer':
        plugin.socketServerGranted = true;
      case 'websocket':
        plugin.websocketGranted = true;
      case 'websocketServer':
        plugin.websocketServerGranted = true;
    }
    await File(
      p.join((await root).path, plugin.manifest.id, markerName),
    ).writeAsString('');
    _notify();
  }

  Future<Object?> _registerSetting(
    InstalledPlugin plugin,
    Map<String, dynamic> spec,
  ) async {
    final setting = LuaPluginSetting.fromSpec(
      pluginId: plugin.manifest.id,
      pluginName: plugin.manifest.name,
      spec: spec,
      persistedValue: plugin.settingValues[spec['id']],
    );
    if (!plugin.settings.any((value) => value.id == setting.id) &&
        plugin.settings.length >= 64) {
      throw const FormatException('Too many plugin settings');
    }
    plugin.settings.removeWhere((value) => value.id == setting.id);
    plugin.settings.add(setting);
    plugin.settingValues[setting.id] = setting.value;
    await _persistSettingValues(plugin);
    _notify();
    return setting.value;
  }

  Future<Object?> _registerPlayerMenuItem(
    InstalledPlugin plugin,
    Map<String, dynamic> spec,
  ) async {
    final item = LuaPlayerMenuItem.fromSpec(
      pluginId: plugin.manifest.id,
      pluginName: plugin.manifest.name,
      spec: spec,
    );
    if (!plugin.playerMenuItems.any((value) => value.id == item.id) &&
        plugin.playerMenuItems.length >= 32) {
      throw const FormatException('Too many plugin player menu items');
    }
    plugin.playerMenuItems.removeWhere((value) => value.id == item.id);
    plugin.playerMenuItems.add(item);
    _notify();
    return true;
  }

  Future<void> _loadSettingValues(InstalledPlugin plugin) async {
    try {
      final file = File(
        p.join(
          (await root).parent.path,
          'lua_plugin_data',
          plugin.manifest.id,
          'ui-settings.json',
        ),
      );
      if (!await file.exists() || await file.length() > 128 * 1024) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        plugin.settingValues
          ..clear()
          ..addAll(Map<String, Object?>.from(decoded));
      }
    } catch (_) {}
  }

  Future<void> _persistSettingValues(InstalledPlugin plugin) async {
    try {
      final file = File(
        p.join(
          (await root).parent.path,
          'lua_plugin_data',
          plugin.manifest.id,
          'ui-settings.json',
        ),
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(plugin.settingValues));
    } catch (_) {}
  }

  Future<void> setPluginSetting(
    String pluginId,
    String settingId,
    Object? value,
  ) async {
    final plugin = _plugins.firstWhere((item) => item.manifest.id == pluginId);
    final index = plugin.settings.indexWhere((item) => item.id == settingId);
    if (index < 0) throw const PluginException('插件设置不存在。');
    final setting = plugin.settings[index];
    if (!setting.accepts(value)) {
      throw const PluginException('插件设置值无效。');
    }
    plugin.settingValues[settingId] = value;
    plugin.settings[index] = setting.copyWithValue(value);
    await _persistSettingValues(plugin);
    _notify();
    try {
      await plugin.runtime?.invoke('setting_changed', {
        'id': settingId,
        'value': value,
      });
    } catch (_) {
      // The value is host-owned and remains available after a plugin restart.
    }
  }

  Future<void> invokePluginSetting(String pluginId, String settingId) async {
    final plugin = _plugins.firstWhere((item) => item.manifest.id == pluginId);
    if (!plugin.settings.any((item) => item.id == settingId)) {
      throw const PluginException('插件设置不存在。');
    }
    await plugin.runtime?.invoke('setting_changed', {
      'id': settingId,
      'value': null,
    });
  }

  Future<void> invokePlayerMenu(
    LuaPlayerMenuItem item,
    Map<String, dynamic> track,
  ) async {
    final plugin = _plugins.firstWhere(
      (value) => value.manifest.id == item.pluginId,
      orElse: () => throw const PluginException('插件不存在。'),
    );
    if (!plugin.playerMenuItems.any((value) => value.id == item.id)) return;
    await plugin.runtime?.invoke('player_menu', {
      'id': item.id,
      'track': track,
    });
  }

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
          await _loadSettingValues(plugin);
          plugin.networkGranted = await File(
            p.join(item.path, '.network-enabled'),
          ).exists();
          plugin.socketGranted = await File(
            p.join(item.path, '.socket-enabled'),
          ).exists();
          plugin.socketServerGranted = await File(
            p.join(item.path, '.socket-server-enabled'),
          ).exists();
          plugin.websocketGranted = await File(
            p.join(item.path, '.websocket-enabled'),
          ).exists();
          plugin.websocketServerGranted = await File(
            p.join(item.path, '.websocket-server-enabled'),
          ).exists();
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
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
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
        networkGranted: plugin.networkGranted,
        socketGranted: plugin.socketGranted,
        socketServerGranted: plugin.socketServerGranted,
        websocketGranted: plugin.websocketGranted,
        websocketServerGranted: plugin.websocketServerGranted,
        permissionRequester: (permission) =>
            _requestPermission(plugin, permission),
        onSettingAdded: (spec) => _registerSetting(plugin, spec),
        onPlayerMenuItemAdded: (spec) => _registerPlayerMenuItem(plugin, spec),
      );
      plugin.runtime = runtime;
      await runtime.start();
      final description = await runtime.invoke('describe');
      final skin = await LuaThemeEngine.load(runtime, description);
      plugin.theme = skin?.theme;
      plugin.layout = skin?.layout;
      MediaRequestRules.register(plugin.manifest.id, [
        for (final rule
            in description is Map && description['media'] is List
                ? description['media'] as List
                : const [])
          if (rule is Map) Map<String, dynamic>.from(rule),
      ], permittedDomains: plugin.manifest.domains);
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
                  : plugin.manifest.auth,
            ),
            loginHint: descriptor['loginHint'] as String?,
            cookieHint: descriptor['cookieHint'] as String?,
            forgotPasswordUrl: descriptor['forgotPasswordUrl'] as String?,
            declaredCapabilities: MusicCapability.parseAll(
              descriptor['capabilities'],
              fallback: plugin.manifest.capabilities,
            ),
          ),
        );
      }
      plugin.error = null;
    } catch (_) {
      MediaRequestRules.remove(plugin.manifest.id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.theme = null;
      plugin.layout = null;
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
      plugin.error = '插件启动失败，请检查插件版本或重新导入。';
    }
  }

  Future<InstalledPlugin> importZip(
    Uint8List bytes, {
    String? expectedId,
    String? expectedVersion,
  }) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    busy = true;
    _notify();
    Directory? staging;
    try {
      await restore();
      final package = await compute(
        decodePluginPackage,
        bytes,
        debugLabel: 'lua-plugin-package',
      );
      final manifest = package.manifest;
      if (expectedId != null && manifest.id != expectedId ||
          expectedVersion != null && manifest.version != expectedVersion) {
        throw const FormatException('插件包与市场信息不一致，请刷新插件源后重试。');
      }
      final base = (await root).absolute;
      staging = await Directory(
        p.join(base.path, '.staging-${DateTime.now().microsecondsSinceEpoch}'),
      ).create();
      for (final file in package.files.entries) {
        final destination = File(
          p.join(staging.path, file.key.replaceAll('/', p.separator)),
        );
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(file.value);
      }
      // Compile and initialize before touching the installed version or its data.
      final probe = LuaPluginRuntime(
        manifest: manifest,
        sources: package.sources,
        dataDirectory: p.join(staging.path, '.probe-data'),
        onSettingAdded: (spec) async => LuaPluginSetting.fromSpec(
          pluginId: manifest.id,
          pluginName: manifest.name,
          spec: spec,
        ).value,
        onPlayerMenuItemAdded: (spec) async {
          LuaPlayerMenuItem.fromSpec(
            pluginId: manifest.id,
            pluginName: manifest.name,
            spec: spec,
          );
          return true;
        },
      );
      try {
        await probe.start();
      } finally {
        await probe.shutdown();
      }
      final previous = _plugins
          .where((v) => v.manifest.id == manifest.id)
          .firstOrNull;
      final enabled = previous?.enabled ?? true;
      await beforeChange?.call(manifest.id);
      await previous?.runtime?.shutdown();
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
        if (previous != null) {
          plugin.settingValues.addAll(previous.settingValues);
        } else {
          await _loadSettingValues(plugin);
        }
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
        await _plugins
            .where((v) => v.manifest.id == manifest.id)
            .firstOrNull
            ?.runtime
            ?.shutdown();
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
      MediaRequestRules.remove(plugin.manifest.id);
      await plugin.runtime?.shutdown();
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

  Future<void> setWebsocketPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((v) => v.manifest.id == id);
    if (plugin.websocketGranted == granted) return;
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.websocketGranted = granted;
      final marker = File(p.join((await root).path, id, '.websocket-enabled'));
      if (granted) {
        await marker.writeAsString('');
      } else if (await marker.exists()) {
        await marker.delete();
      }
      if (plugin.enabled) await _start(plugin);
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setWebsocketServerPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((v) => v.manifest.id == id);
    if (plugin.websocketServerGranted == granted) return;
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.websocketServerGranted = granted;
      final marker = File(
        p.join((await root).path, id, '.websocket-server-enabled'),
      );
      if (granted) {
        await marker.writeAsString('');
      } else if (await marker.exists()) {
        await marker.delete();
      }
      if (plugin.enabled) await _start(plugin);
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setNetworkPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((v) => v.manifest.id == id);
    if (plugin.networkGranted == granted) return;
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.networkGranted = granted;
      final marker = File(p.join((await root).path, id, '.network-enabled'));
      if (granted) {
        await marker.writeAsString('');
      } else if (await marker.exists()) {
        await marker.delete();
      }
      if (plugin.enabled) await _start(plugin);
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setSocketPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((v) => v.manifest.id == id);
    if (plugin.socketGranted == granted) return;
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.socketGranted = granted;
      final marker = File(p.join((await root).path, id, '.socket-enabled'));
      if (granted) {
        await marker.writeAsString('');
      } else if (await marker.exists()) {
        await marker.delete();
      }
      if (plugin.enabled) await _start(plugin);
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setSocketServerPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((v) => v.manifest.id == id);
    if (plugin.socketServerGranted == granted) return;
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.socketServerGranted = granted;
      final marker = File(
        p.join((await root).path, id, '.socket-server-enabled'),
      );
      if (granted) {
        await marker.writeAsString('');
      } else if (await marker.exists()) {
        await marker.delete();
      }
      if (plugin.enabled) await _start(plugin);
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
      MediaRequestRules.remove(plugin.manifest.id);
      await plugin.runtime?.shutdown();
      plugin.gateways.clear();
      final base = (await root).absolute.path;
      final directory = Directory(p.join(base, plugin.manifest.id));
      if (p.dirname(directory.absolute.path) != base) {
        throw const FormatException();
      }
      if (await directory.exists()) await directory.delete(recursive: true);
      // Credentials and storage written by the plugin live beside the plugin
      // directory, not inside it. Uninstalling used to leave session cookies in
      // plaintext, and reinstalling the same id brought them back.
      final dataParent = Directory(p.join(p.dirname(base), 'lua_plugin_data'));
      final data = Directory(p.join(dataParent.path, plugin.manifest.id));
      if (data.absolute.parent.path != dataParent.absolute.path) {
        throw const FormatException();
      }
      if (await data.exists()) await data.delete(recursive: true);
      final backup = Directory(p.join(base, '.backup-${plugin.manifest.id}'));
      if (p.dirname(backup.absolute.path) == base && await backup.exists()) {
        await backup.delete(recursive: true);
      }
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
      MediaRequestRules.remove(plugin.manifest.id);
      plugin.runtime?.close();
    }
    super.dispose();
  }
}
