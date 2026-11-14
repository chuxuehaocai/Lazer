// i18n:data — manager status and validation messages are interface keys shown
// by the plugin manager through `context.tr`.
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
import 'plugin_package.dart';

class InstalledPlugin {
  InstalledPlugin(
    this.manifest, {
    required this.enabled,
    this.runtime,
    this.error,
  });

  final PluginManifest manifest;
  bool enabled;
  bool websocketGranted = false;
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

  void notifyProxyUpdated({required ProxyMode mode, String? endpoint}) {}
  Future<void>? _restoring;

  Future<void> Function(String pluginId)? beforeChange;
  Future<void> Function()? afterChange;

  String _key(String id) => 'lazer.web.plugin.$id';

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
          plugin.websocketGranted = value['websocketGranted'] == true;
          _plugins.add(plugin);
          if (plugin.enabled) await _start(plugin, value['sources']);
        } catch (_) {
          // Ignore a partially written or obsolete browser record.
        }
      }
    } catch (_) {
      // Browser storage can be disabled; the current session remains usable.
    }
    _notify();
  }

  Future<void> _start(InstalledPlugin plugin, [Object? rawSources]) async {
    try {
      final sources = rawSources is Map
          ? Map<String, String>.from(rawSources)
          : <String, String>{};
      if (sources.isEmpty) throw const FormatException('Plugin source missing');
      final runtime = LuaPluginRuntime(
        manifest: plugin.manifest,
        sources: sources,
        dataDirectory: plugin.manifest.id,
        websocketGranted: plugin.websocketGranted,
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
      plugin.runtime?.close();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.theme = null;
      plugin.layout = null;
      plugin.error = '插件启动失败，请检查插件版本或重新导入。';
    }
  }

  Future<void> _save(
    InstalledPlugin plugin,
    Map<String, String> sources,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(plugin.manifest.id),
      jsonEncode(<String, dynamic>{
        'manifest': plugin.manifest.toJson(),
        'sources': sources,
        'enabled': plugin.enabled,
        'websocketGranted': plugin.websocketGranted,
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
      final probe = LuaPluginRuntime(
        manifest: manifest,
        sources: package.sources,
        dataDirectory: '${manifest.id}.probe',
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
      final plugin = InstalledPlugin(manifest, enabled: enabled);
      if (previous != null) _plugins.remove(previous);
      _plugins.add(plugin);
      if (enabled) {
        await _start(plugin, package.sources);
        if (plugin.error != null) {
          _plugins.remove(plugin);
          if (previous != null) {
            _plugins.add(previous);
            await _start(previous);
          }
          throw const PluginException('新插件无法启动，已保留旧版本。');
        }
      }
      await _save(plugin, package.sources);
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
      plugin.runtime?.close();
      plugin.runtime = null;
      plugin.gateways.clear();
      MediaRequestRules.remove(id);
      plugin.enabled = enabled;
      if (enabled) {
        final prefs = await SharedPreferences.getInstance();
        final value = jsonDecode(prefs.getString(_key(id)) ?? '') as Map;
        await _start(plugin, value['sources']);
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
      plugin.runtime?.close();
      plugin.runtime = null;
      plugin.gateways.clear();
      plugin.websocketGranted = granted;
      if (plugin.enabled) await _start(plugin);
      await afterChange?.call();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> uninstall(String id) async {
    if (busy) throw const PluginException('正在处理插件，请稍候。');
    final plugin = _plugins.firstWhere((value) => value.manifest.id == id);
    busy = true;
    _notify();
    try {
      await beforeChange?.call(id);
      plugin.runtime?.close();
      plugin.gateways.clear();
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
