// i18n:data — platform-support messages are interface keys shown by the plugin
// manager through `context.tr`.
import '../state/build_safe_notifier.dart';
import 'package:flutter/foundation.dart';

import 'plugin_manifest.dart';
import '../gateway/music_gateway.dart';
import '../utils/system_http.dart';
import '../theme/lazer_theme.dart';
import '../ui/layout_system.dart';
import 'lua_plugin_runtime.dart';
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
  LazerThemeTokens? theme;
  LazerLayoutDefinition? layout;
  String? error;
}

class PluginManager extends ChangeNotifier with BuildSafeNotifier {
  PluginManager({this.rootDirectory});
  final Object? rootDirectory;
  final List<InstalledPlugin> _plugins = [];
  List<InstalledPlugin> get plugins => List.unmodifiable(_plugins);
  List<MusicGateway> get gateways => const [];
  List<LuaPluginSetting> get pluginSettings => const [];
  List<LuaPlayerMenuItem> get playerMenuItems => const [];
  LazerThemeTokens? get activeTheme => null;
  LazerLayoutDefinition? get activeLayout => null;
  int get skinRevision => 0;
  bool busy = false;
  Future<Object?> Function(Map<String, dynamic> spec)? onPlayerControl;
  void broadcastPlayerEvent(String type, Map<String, dynamic> data) {}

  void notifyProxyUpdated({required ProxyMode mode, String? endpoint}) {}
  Future<void> Function(String pluginId)? beforeChange;
  Future<void> Function()? afterChange;
  Future<bool> Function(InstalledPlugin plugin, String permission)?
  onPermissionRequest;
  Future<void> restore() async {}
  Future<InstalledPlugin> importZip(
    Uint8List bytes, {
    String? expectedId,
    String? expectedVersion,
  }) => Future.error(const PluginException('当前平台不支持 ZIP 插件安装。'));
  Future<void> setEnabled(String id, bool enabled) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> setNetworkPermission(String id, bool granted) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> setSocketPermission(String id, bool granted) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> setSocketServerPermission(String id, bool granted) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> setWebsocketPermission(String id, bool granted) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> setWebsocketServerPermission(String id, bool granted) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> setPluginSetting(
    String pluginId,
    String settingId,
    Object? value,
  ) => Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> invokePluginSetting(String pluginId, String settingId) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> invokePlayerMenu(
    LuaPlayerMenuItem item,
    Map<String, dynamic> track,
  ) => Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> uninstall(String id) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
}
