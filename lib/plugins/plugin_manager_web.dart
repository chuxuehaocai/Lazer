// i18n:data — manager status and validation messages are interface keys shown
// by the plugin manager through `context.tr`.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gateway/lua_music_gateway.dart';
import '../gateway/music_gateway.dart';
import '../state/build_safe_notifier.dart';
import '../utils/media_requests.dart';
import '../utils/system_http.dart';
import '../theme/lazer_theme.dart';
import '../ui/layout_system.dart';
import 'lua_plugin_runtime.dart';
import 'lua_theme_engine.dart';
import 'plugin_manifest.dart';
import 'plugin_data_access.dart';
import 'plugin_package.dart';
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
  bool filesystemGranted = false;
  late final PluginDataAccess dataAccess = PluginDataAccess(manifest);
  final Map<String, Object?> settingValues = <String, Object?>{};
  final List<LuaPluginSetting> settings = <LuaPluginSetting>[];
  final List<LuaPlayerMenuItem> playerMenuItems = <LuaPlayerMenuItem>[];
  final List<LuaPluginPage> pages = <LuaPluginPage>[];
  LuaPluginRuntime? runtime;
  final List<LuaMusicGateway> gateways = <LuaMusicGateway>[];
  LazerThemeTokens? theme;
  LazerLayoutDefinition? layout;
  MusicGateway? get gateway => gateways.firstOrNull;
  String? error;
}

/// In-browser plugin manager.
///
/// ZIP validation and Lua execution stay in Dart. Plugin source is persisted in
/// browser storage because a ZIP can exceed the cookie size limit; the plugin's
/// host storage (including login cookies) is handled by the web runtime's
/// cookie-backed store.
class PluginManager extends ChangeNotifier with BuildSafeNotifier {
  PluginManager({this.rootDirectory});

  final Object? rootDirectory;
  final List<InstalledPlugin> _plugins = <InstalledPlugin>[];
  List<InstalledPlugin> get plugins => List.unmodifiable(_plugins);
  List<MusicGateway> get gateways => <MusicGateway>[
    for (final plugin in _plugins)
      if (plugin.enabled && plugin.runtime != null) ...plugin.gateways,
  ];
  List<LuaPluginSetting> get pluginSettings => <LuaPluginSetting>[
    for (final plugin in _plugins)
      if (plugin.enabled && plugin.runtime != null) ...plugin.settings,
  ];
  List<LuaPlayerMenuItem> get playerMenuItems => <LuaPlayerMenuItem>[
    for (final plugin in _plugins)
      if (plugin.enabled && plugin.runtime != null) ...plugin.playerMenuItems,
  ];
  List<LuaPluginPage> get pluginPages => <LuaPluginPage>[
    for (final plugin in _plugins)
      if (plugin.enabled && plugin.runtime != null) ...plugin.pages,
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
  Future<Object?> Function(Map<String, dynamic> spec)? onPlayerControl;

  void broadcastPlayerEvent(String type, Map<String, dynamic> data) {
    for (final plugin in _plugins) {
      if (!plugin.enabled || plugin.runtime == null) continue;
      unawaited(
        plugin.runtime!
            .invoke('player_event', {'type': type, 'data': data, ...data})
            .catchError((Object _) => null),
      );
    }
  }

  bool _disposed = false;

  void notifyProxyUpdated({required ProxyMode mode, String? endpoint}) {}
  Future<void>? _restoring;

  Future<void> Function(String pluginId)? beforeChange;
  Future<void> Function()? afterChange;
  Future<bool> Function(InstalledPlugin plugin, String permission)?
  onPermissionRequest;

  Future<void> _saveDataPermissions(InstalledPlugin plugin) async {
    if (!_plugins.contains(plugin)) {
      throw const PluginException('Plugin is no longer installed');
    }
    final prefs = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(prefs.getString(_key(plugin.manifest.id)) ?? '{}') as Map;
    saved['dataGranted'] = plugin.dataAccess.granted.toList();
    await prefs.setString(_key(plugin.manifest.id), jsonEncode(saved));
    _notify();
  }

  Future<void> setDataPermission(String id, String scope, bool granted) async {
    final plugin = _plugins.firstWhere((value) => value.manifest.id == id);
    plugin.dataAccess.setGranted(scope, granted);
    await _saveDataPermissions(plugin);
  }

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
    if (permission == 'filesystem' && plugin.filesystemGranted) return true;
    if (onPermissionRequest == null) return false;
    bool granted;
    try {
      granted = await onPermissionRequest!(plugin, permission);
    } catch (_) {
      return false;
    }
    if (granted) await _rememberPermission(plugin, permission);
    return granted;
  }

  Future<void> _rememberPermission(
    InstalledPlugin plugin,
    String permission,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(prefs.getString(_key(plugin.manifest.id)) ?? '{}') as Map;
    switch (permission) {
      case 'network':
        plugin.networkGranted = true;
        saved['networkGranted'] = true;
      case 'socket':
        plugin.socketGranted = true;
        saved['socketGranted'] = true;
      case 'socketServer':
        plugin.socketServerGranted = true;
        saved['socketServerGranted'] = true;
      case 'websocket':
        plugin.websocketGranted = true;
        saved['websocketGranted'] = true;
      case 'websocketServer':
        plugin.websocketServerGranted = true;
        saved['websocketServerGranted'] = true;
      case 'filesystem':
        plugin.filesystemGranted = true;
        saved['filesystemGranted'] = true;
      default:
        return;
    }
    await prefs.setString(_key(plugin.manifest.id), jsonEncode(saved));
    _notify();
  }

  String _key(String id) => 'lazer.web.plugin.$id';

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

  Future<Object?> _registerPage(
    InstalledPlugin plugin,
    Map<String, dynamic> spec,
  ) async {
    final page = LuaPluginPage.fromSpec(
      pluginId: plugin.manifest.id,
      pluginName: plugin.manifest.name,
      spec: spec,
    );
    LuaPluginPageEditor.register(plugin.pages, page);
    _notify();
    return true;
  }

  /// Restyles, re-shapes or extends a page this plugin already registered.
  Future<Object?> _editPage(
    InstalledPlugin plugin,
    Map<String, dynamic> spec,
  ) async {
    final result = LuaPluginPageEditor.apply(
      pages: plugin.pages,
      pluginId: plugin.manifest.id,
      pluginName: plugin.manifest.name,
      spec: spec,
    );
    _notify();
    return result;
  }

  Future<void> _persistSettingValues(InstalledPlugin plugin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(plugin.manifest.id));
      final saved = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      saved['settingValues'] = plugin.settingValues;
      await prefs.setString(_key(plugin.manifest.id), jsonEncode(saved));
    } catch (_) {}
  }

  Future<void> restore() => _restoring ??= _restore();

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().where(
        (value) => value.startsWith('lazer.web.plugin.'),
      )) {
        try {
          final value = jsonDecode(prefs.getString(key) ?? '') as Map;
          final manifest = PluginManifest.fromJson(
            Map<String, dynamic>.from(value['manifest'] as Map),
          );
          final plugin = InstalledPlugin(
            manifest,
            enabled: value['enabled'] != false,
          );
          plugin.networkGranted = value['networkGranted'] == true;
          plugin.socketGranted = value['socketGranted'] == true;
          plugin.socketServerGranted = value['socketServerGranted'] == true;
          plugin.websocketGranted = value['websocketGranted'] == true;
          plugin.websocketServerGranted =
              value['websocketServerGranted'] == true;
          plugin.filesystemGranted = value['filesystemGranted'] == true;
          final grants = value['dataGranted'];
          if (grants is List) {
            for (final scope in manifest.dataPermissions) {
              if (grants.contains(scope)) {
                plugin.dataAccess.setGranted(scope, true);
              }
            }
          }
          final rawSettings = value['settingValues'];
          if (rawSettings is Map) {
            plugin.settingValues.addAll(Map<String, Object?>.from(rawSettings));
          }
          _plugins.add(plugin);
          if (plugin.enabled) {
            await _start(plugin, value['sources'], value['resources']);
          }
        } catch (_) {
          // Ignore a partially written or obsolete browser record.
        }
      }
    } catch (_) {
      // Browser storage can be disabled; the current session remains usable.
    }
    _notify();
  }

  Future<void> _start(
    InstalledPlugin plugin, [
    Object? rawSources,
    Object? rawResources,
  ]) async {
    try {
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
      plugin.pages.clear();
      final sources = rawSources is Map
          ? Map<String, String>.from(rawSources)
          : <String, String>{};
      final resources = rawResources is Map
          ? Map<String, String>.from(rawResources)
          : <String, String>{};
      if (sources.isEmpty) throw const FormatException('Plugin source missing');
      final runtime = LuaPluginRuntime(
        manifest: plugin.manifest,
        sources: sources,
        resources: resources,
        dataDirectory: plugin.manifest.id,
        networkGranted: plugin.networkGranted,
        socketGranted: plugin.socketGranted,
        socketServerGranted: plugin.socketServerGranted,
        websocketGranted: plugin.websocketGranted,
        websocketServerGranted: plugin.websocketServerGranted,
        filesystemGranted: plugin.filesystemGranted,
        permissionRequester: (permission) =>
            _requestPermission(plugin, permission),
        onSettingAdded: (spec) => _registerSetting(plugin, spec),
        onPlayerMenuItemAdded: (spec) => _registerPlayerMenuItem(plugin, spec),
        onPageAdded: (spec) => _registerPage(plugin, spec),
        onPageEdited: (spec) => _editPage(plugin, spec),
        onPlayerControl: (spec) => plugin.dataAccess.dispatch(
          spec,
          prompt: (permission) async =>
              await onPermissionRequest?.call(plugin, permission) ?? false,
          persist: () => _saveDataPermissions(plugin),
          isActive: () => plugin.enabled && _plugins.contains(plugin),
          backend: (request) async {
            if (!plugin.enabled || !_plugins.contains(plugin)) {
              throw const PluginException('Plugin is disabled');
            }
            return onPlayerControl?.call(request);
          },
        ),
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
                : const <Object?>[])
          if (rule is Map) Map<String, dynamic>.from(rule),
      ], permittedDomains: plugin.manifest.domains);
      final declared = description is Map ? description['providers'] : null;
      final providers = declared is List
          ? declared.whereType<Map>().toList()
          : <Map>[
              <String, dynamic>{
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
            provider: MusicProvider(id: providerId, name: name),
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
      plugin.pages.clear();
      plugin.error = '插件启动失败，请检查插件版本或重新导入。';
    }
  }

  Future<void> _save(
    InstalledPlugin plugin,
    Map<String, String> sources,
    Map<String, String> resources,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(plugin.manifest.id),
      jsonEncode(<String, dynamic>{
        'manifest': plugin.manifest.toJson(),
        'sources': sources,
        'resources': resources,
        'enabled': plugin.enabled,
        'networkGranted': plugin.networkGranted,
        'socketGranted': plugin.socketGranted,
        'socketServerGranted': plugin.socketServerGranted,
        'websocketGranted': plugin.websocketGranted,
        'websocketServerGranted': plugin.websocketServerGranted,
        'settingValues': plugin.settingValues,
      }),
    );
  }

  Future<InstalledPlugin> importZip(
    Uint8List bytes, {
    String? expectedId,
    String? expectedVersion,
  }) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    busy = true;
    _notify();
    try {
      await restore();
      final package = decodePluginPackage(bytes);
      final manifest = package.manifest;
      if (expectedId != null && manifest.id != expectedId ||
          expectedVersion != null && manifest.version != expectedVersion) {
        throw const FormatException('插件包与市场信息不一致，请刷新插件源后重试。');
      }
      final probePages = <LuaPluginPage>[];
      final probe = LuaPluginRuntime(
        manifest: manifest,
        sources: package.sources,
        resources: package.resources,
        dataDirectory: '${manifest.id}.probe',
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
        onPageAdded: (spec) async {
          LuaPluginPageEditor.register(
            probePages,
            LuaPluginPage.fromSpec(
              pluginId: manifest.id,
              pluginName: manifest.name,
              spec: spec,
            ),
          );
          return true;
        },
        onPageEdited: (spec) async => LuaPluginPageEditor.apply(
          pages: probePages,
          pluginId: manifest.id,
          pluginName: manifest.name,
          spec: spec,
        ),
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
      final plugin = InstalledPlugin(manifest, enabled: enabled);
      if (previous != null) {
        plugin.settingValues.addAll(previous.settingValues);
      }
      if (previous != null) _plugins.remove(previous);
      _plugins.add(plugin);
      if (enabled) {
        await _start(plugin, package.sources, package.resources);
        if (plugin.error != null) {
          _plugins.remove(plugin);
          if (previous != null) {
            _plugins.add(previous);
            await _start(previous);
          }
          throw const PluginException('新插件无法启动，已保留旧版本。');
        }
      }
      await _save(plugin, package.sources, package.resources);
      await afterChange?.call();
      return plugin;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((value) => value.manifest.id == id);
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
      plugin.pages.clear();
      MediaRequestRules.remove(id);
      plugin.enabled = enabled;
      if (enabled) {
        final prefs = await SharedPreferences.getInstance();
        final value = jsonDecode(prefs.getString(_key(id)) ?? '') as Map;
        await _start(plugin, value['sources'], value['resources']);
      }
      final prefs = await SharedPreferences.getInstance();
      final value = jsonDecode(prefs.getString(_key(id)) ?? '') as Map;
      value['enabled'] = enabled;
      await prefs.setString(_key(id), jsonEncode(value));
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
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
      plugin.pages.clear();
      plugin.websocketGranted = granted;
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(_key(id)) ?? '{}') as Map;
      saved['websocketGranted'] = granted;
      await prefs.setString(_key(id), jsonEncode(saved));
      if (plugin.enabled) {
        await _start(plugin, saved['sources'], saved['resources']);
      }
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setNetworkPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((value) => value.manifest.id == id);
    if (plugin.networkGranted == granted) return;
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
      plugin.pages.clear();
      plugin.networkGranted = granted;
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(_key(id)) ?? '{}') as Map;
      saved['networkGranted'] = granted;
      await prefs.setString(_key(id), jsonEncode(saved));
      if (plugin.enabled) {
        await _start(plugin, saved['sources'], saved['resources']);
      }
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setFilesystemPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((value) => value.manifest.id == id);
    if (plugin.filesystemGranted == granted) return;
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
      plugin.pages.clear();
      plugin.filesystemGranted = granted;
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(_key(id)) ?? '{}') as Map;
      saved['filesystemGranted'] = granted;
      await prefs.setString(_key(id), jsonEncode(saved));
      if (plugin.enabled) {
        await _start(plugin, saved['sources'], saved['resources']);
      }
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setSocketPermission(String id, bool granted) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    throw const PluginException('当前平台不支持原生 Socket。');
  }

  Future<void> setSocketServerPermission(String id, bool granted) =>
      Future.error(const PluginException('浏览器不支持 Socket 服务端。'));

  Future<void> setWebsocketServerPermission(String id, bool granted) =>
      Future.error(const PluginException('浏览器不支持 WebSocket 服务端。'));

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
    } catch (_) {}
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

  Future<void> invokePluginPageEvent(
    String pluginId,
    String pageId,
    String elementId,
    Object? value,
  ) async {
    final plugin = _plugins.firstWhere(
      (item) => item.manifest.id == pluginId,
      orElse: () => throw const PluginException('插件不存在。'),
    );
    final pageIndex = plugin.pages.indexWhere((item) => item.id == pageId);
    if (pageIndex < 0) throw const PluginException('插件页面不存在。');
    final page = plugin.pages[pageIndex];
    final elementIndex = page.elements.indexWhere(
      (item) => item.id == elementId,
    );
    if (elementIndex < 0) throw const PluginException('插件页面控件不存在。');
    final element = page.elements[elementIndex];
    if (!element.accepts(value)) {
      throw const PluginException('插件页面控件值无效。');
    }
    final elements = [...page.elements];
    elements[elementIndex] = element.copyWithValue(value);
    plugin.pages[pageIndex] = page.copyWithElements(elements);
    _notify();
    await plugin.runtime?.invoke('page_event', {
      'page': pageId,
      'id': elementId,
      'value': value,
    });
  }

  Future<void> uninstall(String id) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((value) => value.manifest.id == id);
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      await plugin.runtime?.shutdown();
      plugin.gateways.clear();
      plugin.settings.clear();
      plugin.playerMenuItems.clear();
      plugin.pages.clear();
      MediaRequestRules.remove(id);
      _plugins.remove(plugin);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(id));
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Completes once every installed plugin has released its worker.
  ///
  /// Paired with [dispose], which cannot await. This variant has no worker to
  /// wait for, so it completes immediately.
  Future<void> get shutdownSettled => Future.wait<void>(<Future<void>>[
    for (final plugin in _plugins)
      plugin.runtime?.settled ?? Future<void>.value(),
  ]);

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
