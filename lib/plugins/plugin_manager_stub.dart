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
  LazerThemeTokens? get activeTheme => null;
  LazerLayoutDefinition? get activeLayout => null;
  int get skinRevision => 0;
  bool busy = false;

  void notifyProxyUpdated({required ProxyMode mode, String? endpoint}) {}
  Future<void> Function(String pluginId)? beforeChange;
  Future<void> Function()? afterChange;
  Future<void> restore() async {}
  Future<InstalledPlugin> importZip(
    Uint8List bytes, {
    String? expectedId,
    String? expectedVersion,
  }) => Future.error(const PluginException('当前平台不支持 ZIP 插件安装。'));
  Future<void> setEnabled(String id, bool enabled) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> setWebsocketPermission(String id, bool granted) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<void> uninstall(String id) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
}
