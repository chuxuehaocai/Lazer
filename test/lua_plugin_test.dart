import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';

void main() {
  test(
    'nested Lua HTTP resumes locals, loops, tail calls and protected errors',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-lua-http-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final requests = <String>[];
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'demo.async',
          'name': 'Async',
          'version': '1.0.0',
          'provider': 'async',
          'apiVersion': 1,
          'permissions': {
            'network': ['fixture.test'],
            'storage': true,
          },
        }),
        sources: const {
          'main.lua': '''
        local function inner(n)
          local response = host.http({url="https://fixture.test/" .. n})
          return host.json_decode(response.body).value
        end
        local function nested(n) return inner(n) end
        return {call=function(op,args)
          if op == "bad" then return host.http({url="https://denied.test/"}) end
          if op == "recover" then
            local ok = pcall(function() nested("fail") end)
            return {ok=ok,value=nested(9)}
          end
          local total = 10
          for i=1,3 do total=total+nested(i) end
          host.storage_set("total",total)
          return {total=total,stored=host.storage_get("total"),counter=args.counter}
        end}
      ''',
        },
        dataDirectory: directory.path,
        httpHandler: (spec) async {
          final path = Uri.parse(spec['url'] as String).path;
          requests.add(path);
          await Future<void>.delayed(const Duration(milliseconds: 3));
          if (path == '/fail') throw StateError('fixture failure');
          return {
            'status': 200,
            'headers': <String, dynamic>{},
            'body': jsonEncode({'value': int.parse(path.substring(1))}),
          };
        },
      );
      addTearDown(runtime.close);
      expect(await runtime.invoke('sum', {'counter': 7}), {
        'total': 16,
        'stored': 16,
        'counter': 7,
      });
      expect(requests, ['/1', '/2', '/3']);
      expect(await runtime.invoke('recover'), {'ok': false, 'value': 9});
      await expectLater(runtime.invoke('bad'), throwsA(isA<PluginException>()));
      expect(requests, isNot(contains('https://denied.test/')));
      expect(await runtime.invoke('sum', {'counter': 8}), {
        'total': 16,
        'stored': 16,
        'counter': 8,
      });
    },
  );

  test('manifest rejects traversal and non-HTTPS wildcard permissions', () {
    expect(
      () => PluginManifest.fromJson(const {
        'id': 'demo.test',
        'name': 'Demo',
        'version': '1.0.0',
        'provider': 'demo',
        'apiVersion': 1,
        'entry': '../main.lua',
      }),
      throwsFormatException,
    );
    expect(PluginManifest.safePath('lib/api.lua'), isTrue);
    expect(PluginManifest.safePath('../api.lua'), isFalse);
  });

  test('Lua entrypoint and module calls remain data-only', () async {
    final runtime = LuaPluginRuntime(
      manifest: PluginManifest.fromJson(const {
        'id': 'demo.runtime',
        'name': 'Demo',
        'version': '1.0.0',
        'provider': 'demo',
        'apiVersion': 1,
        'entry': 'main.lua',
        'permissions': {'storage': true},
      }),
      sources: {
        'main.lua': '''
          local helper = require("helper")
          return { call = function(op, args)
            if op == "sum" then return {value = helper.add(args.a, args.b), hash = host.crypto({operation="md5", text="abc"})} end
          end }
        ''',
        'helper.lua': 'return { add = function(a, b) return a + b end }',
      },
      dataDirectory: '.dart_tool/lua-plugin-test',
    );
    addTearDown(runtime.close);
    expect(await runtime.invoke('sum', {'a': 20, 'b': 22}), {
      'value': 42,
      'hash': '900150983cd24fb0d6963f7d28e17f72',
    });
  });

  test('ZIP import validates, probes, installs and toggles a plugin', () async {
    final root = await Directory.systemTemp.createTemp('lazer-plugin-test');
    addTearDown(() => root.delete(recursive: true));
    final manifestBytes = utf8.encode(
      jsonEncode(const {
        'id': 'demo.manager',
        'name': 'Demo',
        'version': '1.0.0',
        'provider': 'demo',
        'apiVersion': 1,
        'entry': 'main.lua',
        'permissions': {'storage': true},
      }),
    );
    final sourceBytes = utf8.encode('return {call=function() return {} end}');
    final archive = Archive()
      ..addFile(
        ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
      )
      ..addFile(ArchiveFile('main.lua', sourceBytes.length, sourceBytes));
    final manager = PluginManager(rootDirectory: root);
    addTearDown(manager.dispose);
    final plugin = await manager.importZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    expect(plugin.manifest.id, 'demo.manager');
    expect(manager.plugins.single.enabled, isTrue);
    await manager.setEnabled('demo.manager', false);
    expect(manager.plugins.single.enabled, isFalse);
  });
}
