import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_market.dart';

Uint8List package({String id = 'fixture.market', String version = '1.0.0'}) {
  final archive = Archive();
  final files = {
    'manifest.json': jsonEncode({
      'id': id,
      'provider': 'fixture',
      'name': 'Fixture',
      'version': version,
      'apiVersion': 1,
    }),
    'main.lua': 'return {call=function(op,args) return {} end}',
  };
  for (final file in files.entries) {
    final bytes = utf8.encode(file.value);
    archive.addFile(ArchiveFile(file.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, dynamic> entry({
  String id = 'fixture.market',
  String version = '1.0.0',
  Uint8List? bytes,
}) => {
  'id': id,
  'version': version,
  'name': {'zh-CN': '测试平台', 'en': 'Test platform'},
  'summary': 'A music platform',
  'author': 'Fixture',
  'download': 'fixture.zip',
  // A market entry installs executable code, so the fixture carries the hash of
  // the exact package bytes its download URL serves.
  'sha256': sha256
      .convert(bytes ?? package(id: id, version: version))
      .toString(),
  'platforms': ['windows', 'linux', 'macos', 'android', 'ios'],
  'minAppVersion': '2.0.0-beta.6',
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PluginManager manager;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('market-');
    manager = PluginManager(rootDirectory: root);
  });
  tearDown(() async {
    manager.dispose();
    await root.delete(recursive: true);
  });
  test('uninstall removes the credentials stored beside the plugin', () async {
    await manager.importZip(package());
    final plugin = manager.plugins.single;
    final Directory data = Directory(
      p.join(root.parent.path, 'lua_plugin_data', plugin.manifest.id),
    );
    await data.create(recursive: true);
    await File(
      p.join(data.path, 'storage.json'),
    ).writeAsString('{"token":"secret"}');
    await manager.uninstall(plugin.manifest.id);
    expect(manager.plugins, isEmpty);
    expect(await data.exists(), isFalse);
  });
  test('default and custom sources normalize directory and JSON URLs', () {
    expect(
      pluginIndexUri(defaultPluginSource).toString(),
      'https://lazer.naominet.dev/plugin/plugins.json',
    );
    expect(
      pluginIndexUri('https://example.test/path/').path,
      '/path/plugins.json',
    );
    expect(
      pluginIndexUri('https://example.test/index.json').path,
      '/index.json',
    );
    expect(() => pluginIndexUri('http://example.test'), throwsFormatException);
    expect(
      () => pluginIndexUri('https://user:secret@example.test'),
      throwsFormatException,
    );
  });
  test(
    'catalogue reads the website schema, localization and compatibility',
    () async {
      Uri? requested;
      final market = PluginMarket(
        manager,
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'plugins': [entry()],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(market.dispose);
      await market.refresh();
      expect(market.error, isNull);
      expect(requested!.path, '/plugin/plugins.json');
      final plugin = market.plugins.single;
      expect(plugin.localized(plugin.name, 'zh-CN'), '测试平台');
      expect(plugin.localized(plugin.name, 'en'), 'Test platform');
      for (final platform in ['windows', 'linux', 'macos', 'android', 'ios']) {
        expect(plugin.incompatibility(platform, '2.0.0-beta.6'), isNull);
      }
      expect(plugin.incompatibility('windows', '1.9.0'), isNotNull);
      expect(plugin.incompatibility('fuchsia', '2.0.0'), isNotNull);
      expect(plugin.download.path, '/plugin/fixture.zip');
    },
  );
  test(
    'source selection persists and an empty source is a valid result',
    () async {
      final market = PluginMarket(
        manager,
        client: MockClient(
          (_) async => http.Response('{"schemaVersion":1,"plugins":[]}', 200),
        ),
      );
      addTearDown(market.dispose);
      await market.setSource('https://example.test/custom/');
      expect(market.plugins, isEmpty);
      expect(market.error, isNull);
      final restarted = PluginMarket(
        manager,
        client: MockClient(
          (_) async => http.Response('{"schemaVersion":1,"plugins":[]}', 200),
        ),
      );
      addTearDown(restarted.dispose);
      await restarted.restore();
      expect(restarted.source, 'https://example.test/custom/');
    },
  );
  test('market download installs and updates real Lua ZIPs', () async {
    var version = '1.0.0';
    final packages = <String, Uint8List>{
      '1.0.0': package(version: '1.0.0'),
      '1.1.0': package(version: '1.1.0'),
    };
    final market = PluginMarket(
      manager,
      client: MockClient(
        (request) async => request.url.path.endsWith('.json')
            ? http.Response(
                jsonEncode({
                  'schemaVersion': 1,
                  'plugins': [
                    entry(version: version, bytes: packages[version]),
                  ],
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              )
            : http.Response.bytes(packages[version]!, 200),
      ),
    );
    addTearDown(market.dispose);
    await market.refresh();
    await market.install(market.plugins.single);
    expect(market.error, isNull);
    expect(manager.plugins.single.manifest.version, '1.0.0');
    version = '1.1.0';
    await market.refresh();
    await market.install(market.plugins.single);
    expect(market.error, isNull);
    expect(manager.plugins.single.manifest.version, '1.1.0');
  });
  test('manifest identity mismatch preserves the installed plugin', () async {
    await manager.importZip(package());
    final Uint8List other = package(id: 'other.plugin', version: '1.1.0');
    final market = PluginMarket(
      manager,
      client: MockClient(
        (_) async => http.Response.bytes(other, 200),
      ),
    );
    addTearDown(market.dispose);
    await market.install(
      MarketPlugin.fromJson(
        entry(version: '1.1.0', bytes: other),
        pluginIndexUri(defaultPluginSource),
      ),
    );
    expect(market.error, isNotNull);
    expect(manager.plugins.single.manifest.id, 'fixture.market');
    expect(manager.plugins.single.manifest.version, '1.0.0');
  });
  test(
    'checksum failure and unsafe index entries never install a ZIP',
    () async {
      final market = PluginMarket(
        manager,
        client: MockClient((_) async => http.Response.bytes(package(), 200)),
      );
      addTearDown(market.dispose);
      final bad = entry()..['sha256'] = '0' * 64;
      await market.install(
        MarketPlugin.fromJson(bad, pluginIndexUri(defaultPluginSource)),
      );
      expect(market.error, contains('校验失败'));
      expect(manager.plugins, isEmpty);
      expect(
        () => MarketPlugin.fromJson(
          entry()..['download'] = 'http://invalid.test/package.zip',
          pluginIndexUri(defaultPluginSource),
        ),
        throwsFormatException,
      );
      expect(
        () => MarketPlugin.fromJson(
          entry()..remove('sha256'),
          pluginIndexUri(defaultPluginSource),
        ),
        throwsFormatException,
        reason: 'a market package without a checksum is not installable',
      );
    },
  );
  test(
    'cancelling a streaming download closes its subscription without installing',
    () async {
      var cancelled = false;
      final chunks = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final market = PluginMarket(
        manager,
        client: MockClient.streaming(
          (_, _) async =>
              http.StreamedResponse(chunks.stream, 200, contentLength: 1000),
        ),
      );
      addTearDown(market.dispose);
      final progressed = Completer<void>();
      market.addListener(() {
        if (market.progress != null && !progressed.isCompleted) {
          progressed.complete();
        }
      });
      final installing = market.install(
        MarketPlugin.fromJson(entry(), pluginIndexUri(defaultPluginSource)),
      );
      chunks.add([1, 2, 3]);
      await progressed.future;
      market.cancelDownload();
      await installing;
      expect(cancelled, isTrue);
      expect(manager.plugins, isEmpty);
      expect(market.installing, isNull);
      expect(market.error, isNull);
      await chunks.close();
    },
  );
  test('HTTP errors remain visible and a later refresh can recover', () async {
    var fail = true;
    final market = PluginMarket(
      manager,
      client: MockClient(
        (_) async => fail
            ? http.Response('', 503)
            : http.Response('{"schemaVersion":1,"plugins":[]}', 200),
      ),
    );
    addTearDown(market.dispose);
    await market.refresh();
    expect(market.loading, isFalse);
    expect(market.error, contains('503'));
    fail = false;
    await market.refresh();
    expect(market.error, isNull);
  });
}
