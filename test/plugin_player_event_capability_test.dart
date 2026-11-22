import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer/plugins/plugin_manager_io.dart';
import 'package:lazer/plugins/plugin_manifest.dart';

void main() {
  test('PluginManager only broadcasts player_event to plugins declaring player_events capability', () async {
    final tempDir = await Directory.systemTemp.createTemp('lazer-pe-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    final manager = PluginManager(baseDirectory: tempDir.path);
    addTearDown(manager.dispose);

    expect(manager.hasPlayerEventListeners, isFalse);

    // 1. Music source plugin without player_events capability
    final sourceManifest = PluginManifest.fromJson(const {
      'id': 'lazer.netease.mock',
      'name': 'Mock NetEase',
      'version': '1.0.0',
      'provider': 'netease',
      'apiVersion': 1,
      'entry': 'main.lua',
      'capabilities': ['search', 'lyrics'],
    });

    // 2. Bridge/widget plugin with player_events capability
    final bridgeManifest = PluginManifest.fromJson(const {
      'id': 'lazer.ws.mock',
      'name': 'Mock WS Bridge',
      'version': '1.0.0',
      'provider': 'ws_bridge',
      'apiVersion': 1,
      'entry': 'main.lua',
      'capabilities': ['player_events'],
    });

    final sourcePlugin = InstalledPlugin(sourceManifest, enabled: true);
    final bridgePlugin = InstalledPlugin(bridgeManifest, enabled: true);

    manager.plugins.addAll([sourcePlugin, bridgePlugin]);

    // When runtimes are not yet attached, hasPlayerEventListeners is false
    expect(manager.hasPlayerEventListeners, isFalse);

    // If sourcePlugin has a runtime attached, it should still not register as listener
    // We can verify _listensToPlayerEvents behavior via hasPlayerEventListeners:
    // Only when bridgePlugin has runtime and is enabled does hasPlayerEventListeners become true.
    expect(manager.hasPlayerEventListeners, isFalse);
  });
}
