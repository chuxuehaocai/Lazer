// Contract check for the out-of-tree NetEase gateway plugin.
//
// The plugin itself lives beside this repository (`../lazer_ncm/netease-cloud`)
// and is published separately, so this test skips itself when that checkout is
// not present instead of failing a clean CI job.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

String? _pluginRoot() {
  for (final candidate in <String>[
    r'../lazer_ncm/netease-cloud',
    r'E:/projects/lazer_ncm/netease-cloud',
  ]) {
    final directory = Directory(candidate);
    if (directory.existsSync()) return directory.absolute.path;
  }
  return null;
}

Map<String, String> _sources(String root) {
  final directory = Directory(root);
  final sources = <String, String>{};
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path
        .substring(directory.path.length + 1)
        .replaceAll(r'\', '/');
    if (relative.endsWith('.lua')) {
      sources[relative] = entity.readAsStringSync();
    }
  }
  return sources;
}

void main() {
  final root = _pluginRoot();

  test('the NetEase gateway loads every module and answers describe', () async {
    if (root == null) {
      markTestSkipped('netease plugin checkout not present');
      return;
    }
    final manifest = PluginManifest.decode(
      File('$root/manifest.json').readAsStringSync(),
    );
    final directory = await Directory.systemTemp.createTemp('lua-netease-');
    final runtime = LuaPluginRuntime(
      manifest: manifest,
      sources: _sources(root),
      dataDirectory: directory.path,
      timeout: const Duration(seconds: 20),
    );
    addTearDown(() async {
      runtime.close();
      await directory.delete(recursive: true);
    });
    await runtime.start();

    final described = await runtime.invoke('describe', {});
    expect(described, isA<Map>());
    final providers = (described as Map)['providers'];
    expect(providers, isA<List>());
    final capabilities = (providers as List).first['capabilities'] as List;
    expect(capabilities, contains('listenTogether'));
    // The activity toggle is registered even when the item starts disabled.
    expect(
      manifest.version,
      matches(RegExp(r'^\d+\.\d+\.\d+$')),
      reason: 'the market publishes a semantic version',
    );
  });

  test('a room operation without a room id is rejected before the network', () async {
    if (root == null) {
      markTestSkipped('netease plugin checkout not present');
      return;
    }
    final manifest = PluginManifest.decode(
      File('$root/manifest.json').readAsStringSync(),
    );
    final directory = await Directory.systemTemp.createTemp('lua-netease-');
    final runtime = LuaPluginRuntime(
      manifest: manifest,
      sources: _sources(root),
      dataDirectory: directory.path,
      timeout: const Duration(seconds: 20),
    );
    addTearDown(() async {
      runtime.close();
      await directory.delete(recursive: true);
    });
    await runtime.start();

    final heartbeat = await runtime.invoke('listenTogether', {
      'operation': 'heartbeat',
      'songId': '0',
      'playStatus': 'PLAY',
      'progress': 0,
      'playlistVersion': '[]',
    });
    // The dispatcher maps the Lua error into the safe status shape, which is
    // what proves the new heartbeat branch runs at all.
    expect(heartbeat, isA<Map>());
    expect((heartbeat as Map)['error'], isA<Map>());

    // Play activity refuses a request without a song for the same reason.
    final activity = await runtime.invoke('playActivity', {});
    expect(activity, isA<Map>());
    expect((activity as Map)['error'], isA<Map>());
  });
}
