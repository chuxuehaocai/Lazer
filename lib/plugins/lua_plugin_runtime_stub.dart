// i18n:data — platform-support messages are interface keys shown by the plugin
// UI through `context.tr`.
import 'plugin_manifest.dart';
import '../utils/system_http.dart';

/// Web-safe facade. Browser deployments can still inspect plugin metadata;
/// network plugins are enabled by the native client where ZIP storage and
/// isolates are available.
class LuaPluginRuntime {
  LuaPluginRuntime({
    required this.manifest,
    required this.sources,
    this.resources = const <String, String>{},
    required this.dataDirectory,
    this.timeout = const Duration(seconds: 40),
    this.httpHandler,
    this.networkGranted = false,
    this.socketGranted = false,
    this.socketServerGranted = false,
    this.websocketGranted = false,
    this.websocketServerGranted = false,
    this.filesystemGranted = false,
    this.permissionRequester,
    this.onSettingAdded,
    this.onPlayerMenuItemAdded,
    this.onPlayerControl,
    this.onLog,
  });
  final PluginManifest manifest;
  final Map<String, String> sources;
  final Map<String, String> resources;
  final String dataDirectory;
  final Duration timeout;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  httpHandler;
  final bool networkGranted;
  final bool socketGranted;
  final bool socketServerGranted;
  final bool websocketGranted;
  final bool websocketServerGranted;
  final bool filesystemGranted;
  final Future<bool> Function(String permission)? permissionRequester;
  final Future<Object?> Function(Map<String, dynamic> spec)? onSettingAdded;
  final Future<Object?> Function(Map<String, dynamic> spec)?
  onPlayerMenuItemAdded;
  final Future<Object?> Function(Map<String, dynamic> spec)? onPlayerControl;
  final void Function(Map<String, dynamic> record)? onLog;
  Future<void> start() =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
  Future<Object?> invoke(
    String operation, [
    Map<String, dynamic> args = const {},
    Duration? budget,
  ]) => Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));

  /// Completes once the runtime holds no worker or listener.
  ///
  /// The native implementation waits for its isolate to release the listen
  /// ports; the browser build has nothing to release, so this is immediate.
  Future<void> get settled => Future<void>.value();

  Future<void> shutdown() async {
    close();
  }

  void close() {}
  void updateProxy({required ProxyMode mode, String? endpoint}) {}
  Future<List<String>> evaluate(String source) =>
      Future.error(const PluginException('当前平台不支持 Lua 插件运行时。'));
}
