// i18n:data — platform-support messages are interface keys shown by the plugin
// UI through `context.tr`.
import 'plugin_manifest.dart';

/// Web-safe facade. Browser deployments can still inspect plugin metadata;
/// network plugins are enabled by the native client where ZIP storage and
/// isolates are available.
class LuaPluginRuntime {
  LuaPluginRuntime({
    required this.manifest,
    required this.sources,
    required this.dataDirectory,
    this.timeout = const Duration(seconds: 40),
    this.httpHandler,
    this.websocketGranted = false,
  });
  final PluginManifest manifest;
  final Map<String, String> sources;
  final String dataDirectory;
  final Duration timeout;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  httpHandler;
  final bool websocketGranted;
  Future<void> start() =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<Object?> invoke(
    String operation, [
    Map<String, dynamic> args = const {},
    Duration? budget,
  ]) => Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  void close() {}
  Future<List<String>> evaluate(String source) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
}
