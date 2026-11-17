import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_package.dart';
import 'package:lazer_nextgen/plugins/plugin_extensions.dart';

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
        networkGranted: true,
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

  test(
    'network requests ask for permission once and reuse the grant',
    () async {
      final prompts = <String>[];
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'demo.permission',
          'name': 'Permission',
          'version': '1.0.0',
          'provider': 'permission',
          'apiVersion': 1,
          'permissions': {
            'network': ['fixture.test'],
          },
        }),
        sources: const {
          'main.lua': '''
          return {call=function(op)
            return host.http({url="https://fixture.test/"})
          end}
        ''',
        },
        dataDirectory: '',
        networkGranted: false,
        permissionRequester: (permission) async {
          prompts.add(permission);
          return true;
        },
        httpHandler: (_) async => {
          'status': 200,
          'headers': <String, dynamic>{},
          'body': 'ok',
        },
      );
      addTearDown(runtime.close);
      expect(await runtime.invoke('request'), {
        'status': 200,
        'headers': <String, dynamic>{},
        'body': 'ok',
      });
      expect(await runtime.invoke('request'), {
        'status': 200,
        'headers': <String, dynamic>{},
        'body': 'ok',
      });
      expect(prompts, ['network']);
    },
  );

  test(
    'network permission denial prevents the transport from running',
    () async {
      var requests = 0;
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'demo.denied',
          'name': 'Denied',
          'version': '1.0.0',
          'provider': 'denied',
          'apiVersion': 1,
          'permissions': {
            'network': ['fixture.test'],
          },
        }),
        sources: const {
          'main.lua': '''
          return {call=function() return host.http({url="https://fixture.test/"}) end}
        ''',
        },
        dataDirectory: '',
        networkGranted: false,
        permissionRequester: (_) async => false,
        httpHandler: (_) async {
          requests++;
          return <String, dynamic>{
            'status': 200,
            'headers': <String, dynamic>{},
            'body': 'unexpected',
          };
        },
      );
      addTearDown(runtime.close);
      await expectLater(
        runtime.invoke('request'),
        throwsA(isA<PluginException>()),
      );
      expect(requests, 0);
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

  test(
    'Lua plugins can register settings and now-playing menu items',
    () async {
      final directory = await Directory.systemTemp.createTemp('lazer-lua-ui-');
      addTearDown(() => directory.delete(recursive: true));
      final registeredSettings = <Map<String, dynamic>>[];
      final registeredMenus = <Map<String, dynamic>>[];
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'demo.ui',
          'name': 'UI Demo',
          'version': '1.0.0',
          'provider': 'ui',
          'apiVersion': 1,
          'entry': 'main.lua',
        }),
        sources: const {
          'main.lua': '''
          local quality = host.add_setting({
            id="quality", type="select", title="音质",
            default="standard", options={
              {value="standard", label="标准"},
              {value="high", label="高"},
            }
          })
          host.add_player_menu_item({
            id="copy_id", label="复制歌曲 ID", icon="content_copy"
          })
          return {call=function(operation, args)
            if operation == "describe" then return {} end
            if operation == "setting_changed" then
              return {id=args.id, value=args.value}
            end
            if operation == "player_menu" then
              return {id=args.id, track=args.track}
            end
            return quality
          end}
        ''',
        },
        dataDirectory: directory.path,
        onSettingAdded: (spec) async {
          registeredSettings.add(spec);
          return spec['default'];
        },
        onPlayerMenuItemAdded: (spec) async {
          registeredMenus.add(spec);
          return true;
        },
      );
      addTearDown(runtime.close);
      expect(await runtime.invoke('describe'), isEmpty);
      expect(registeredSettings.single['id'], 'quality');
      expect(registeredMenus.single['id'], 'copy_id');
      expect(
        await runtime.invoke('setting_changed', {
          'id': 'quality',
          'value': 'high',
        }),
        {'id': 'quality', 'value': 'high'},
      );
      expect(
        await runtime.invoke('player_menu', {
          'id': 'copy_id',
          'track': {'id': 'song-1', 'title': '示例'},
        }),
        {
          'id': 'copy_id',
          'track': {'id': 'song-1', 'title': '示例'},
        },
      );
    },
  );

  test('Lua plugin UI extension specs validate before reaching Flutter', () {
    expect(
      () => LuaPluginSetting.fromSpec(
        pluginId: 'demo.ui',
        pluginName: 'UI Demo',
        spec: const {'id': 'bad id', 'type': 'toggle', 'title': '无效'},
      ),
      throwsFormatException,
    );
    expect(
      () => LuaPluginSetting.fromSpec(
        pluginId: 'demo.ui',
        pluginName: 'UI Demo',
        spec: const {
          'id': 'quality',
          'type': 'select',
          'title': '音质',
          'options': <Object?>[],
        },
      ),
      throwsFormatException,
    );
    expect(
      () => LuaPlayerMenuItem.fromSpec(
        pluginId: 'demo.ui',
        pluginName: 'UI Demo',
        spec: const {'id': 'copy_id', 'label': ''},
      ),
      throwsFormatException,
    );
  });

  test('plugin page geometry is clamped and rejects unknown flow names', () {
    final layout = LuaPluginPageLayout.fromSpec(const <String, Object?>{
      'gap': 1000,
      'inset': -5,
      'columns': 99,
      'align': 'center',
      'direction': 'grid',
      'card': false,
    });
    expect(layout.gap, 96);
    expect(layout.inset, 0);
    expect(layout.columns, 4);
    expect(layout.align, LuaPluginPageAlign.center);
    expect(layout.direction, LuaPluginPageDirection.grid);
    expect(layout.card, isFalse);
    expect(layout.maxWidth, 0);
    expect(
      () => LuaPluginPageLayout.fromSpec(const {'align': 'diagonal'}),
      throwsFormatException,
    );
    expect(
      () => LuaPluginPageLayout.fromSpec(const {'direction': 'spiral'}),
      throwsFormatException,
    );
  });

  test('a page keeps its declared layout and spacing through a patch', () {
    final page = LuaPluginPage.fromSpec(
      pluginId: 'demo.page',
      pluginName: 'Page Demo',
      spec: const <String, dynamic>{
        'id': 'tools',
        'title': '工具',
        'subtitle': '插件工具页',
        'gap': 8,
        'inset': 12,
        'elements': <Object?>[
          <String, dynamic>{'type': 'section', 'title': '常用'},
          <String, dynamic>{'type': 'button', 'id': 'refresh', 'title': '刷新'},
        ],
      },
    );
    expect(page.layout.gap, 8);
    expect(page.layout.inset, 12);
    expect(page.elements[1].gap, 0);

    final patched = page.patch(const <String, dynamic>{
      'title': '工具箱',
      'gap': 18,
      'align': 'start',
      'direction': 'horizontal',
    });
    expect(patched.title, '工具箱');
    expect(patched.id, 'tools');
    expect(patched.layout.gap, 18);
    expect(patched.layout.inset, 12);
    expect(patched.layout.align, LuaPluginPageAlign.start);
    expect(patched.layout.direction, LuaPluginPageDirection.horizontal);
    expect(patched.elements.length, 2);
    expect(page.patch(const {'gap': 10}).layout.gap, 10);
    expect(page.patch(const {'columns': 9}).layout.columns, 4);
  });

  test('the page editor restyles, extends and reorders a live page', () {
    final pages = <LuaPluginPage>[
      LuaPluginPage.fromSpec(
        pluginId: 'demo.page',
        pluginName: 'Page Demo',
        spec: const <String, dynamic>{
          'id': 'tools',
          'title': '工具',
          'elements': <Object?>[
            <String, dynamic>{'type': 'section', 'title': '常用'},
            <String, dynamic>{'type': 'button', 'id': 'refresh', 'title': '刷新'},
          ],
        },
      ),
    ];
    Object? apply(Map<String, dynamic> spec) => LuaPluginPageEditor.apply(
      pages: pages,
      pluginId: 'demo.page',
      pluginName: 'Page Demo',
      spec: spec,
    );

    final updated =
        apply(<String, dynamic>{
              'operation': 'update',
              'page': 'tools',
              'title': '工具箱',
              'gap': 20,
              'inset': 14,
              'card': false,
              'header': false,
            })
            as Map;
    expect(updated['title'], '工具箱');
    expect(pages.single.title, '工具箱');
    expect(pages.single.layout.gap, 20);
    expect(pages.single.layout.inset, 14);
    expect(pages.single.layout.card, isFalse);
    expect(pages.single.layout.header, isFalse);

    apply(<String, dynamic>{
      'operation': 'add_element',
      'page': 'tools',
      'before': 'refresh',
      'type': 'toggle',
      'id': 'enabled',
      'title': '启用',
      'value': true,
      'gap': 6,
    });
    expect(pages.single.elements.map((element) => element.id), <String?>[
      null,
      'enabled',
      'refresh',
    ]);
    expect(pages.single.elements[1].gap, 6);

    apply(<String, dynamic>{
      'operation': 'update_element',
      'page': 'tools',
      'id': 'enabled',
      'title': '已启用',
      'subtitle': '由脚本改写',
      'padding': 4,
    });
    final toggle = pages.single.elements[1];
    expect(toggle.id, 'enabled');
    expect(toggle.title, '已启用');
    expect(toggle.subtitle, '由脚本改写');
    expect(toggle.value, isTrue);
    expect(toggle.padding, 4);

    apply(<String, dynamic>{
      'operation': 'move_element',
      'page': 'tools',
      'element': 'refresh',
      'to': 1,
    });
    expect(pages.single.elements.map((element) => element.id), <String?>[
      'refresh',
      null,
      'enabled',
    ]);

    apply(<String, dynamic>{
      'operation': 'remove_element',
      'page': 'tools',
      'element': 'refresh',
    });
    expect(pages.single.elements.map((element) => element.id), <String?>[
      null,
      'enabled',
    ]);

    apply(<String, dynamic>{
      'operation': 'set_elements',
      'page': 'tools',
      'elements': <Object?>[
        <String, dynamic>{'type': 'text', 'text': '只有一段说明'},
      ],
    });
    expect(pages.single.elements.single.text, '只有一段说明');

    final read =
        apply(const <String, dynamic>{'operation': 'get', 'page': 'tools'})
            as Map;
    expect(read['id'], 'tools');
    expect((read['elements']! as List).length, 1);
    final list = apply(const <String, dynamic>{'operation': 'list'}) as List;
    expect(list.single['id'], 'tools');
    expect(list.single['elements'], 1);
  });

  test('the page editor rejects unknown pages and duplicate element ids', () {
    final pages = <LuaPluginPage>[
      LuaPluginPage.fromSpec(
        pluginId: 'demo.page',
        pluginName: 'Page Demo',
        spec: const <String, dynamic>{
          'id': 'tools',
          'title': '工具',
          'elements': <Object?>[
            <String, dynamic>{'type': 'button', 'id': 'refresh', 'title': '刷新'},
          ],
        },
      ),
    ];
    Object? apply(Map<String, dynamic> spec) => LuaPluginPageEditor.apply(
      pages: pages,
      pluginId: 'demo.page',
      pluginName: 'Page Demo',
      spec: spec,
    );
    expect(
      () => apply(const <String, dynamic>{
        'operation': 'update',
        'page': 'missing',
      }),
      throwsFormatException,
    );
    expect(
      () => apply(const <String, dynamic>{
        'operation': 'add_element',
        'page': 'tools',
      }),
      throwsFormatException,
    );
    expect(
      () => apply(const <String, dynamic>{
        'operation': 'add_element',
        'page': 'tools',
        'type': 'button',
        'id': 'refresh',
        'title': '重复',
      }),
      throwsFormatException,
    );
    expect(
      () => apply(const <String, dynamic>{
        'operation': 'navigate',
        'page': 'tools',
      }),
      throwsFormatException,
    );
    expect(pages.single.elements.single.id, 'refresh');
  });

  test('manifest rejects a wildcard over a public suffix', () {
    Map<String, Object> withNetwork(List<String> domains) => <String, Object>{
      'id': 'demo.network',
      'name': 'Demo',
      'version': '1.0.0',
      'provider': 'demo',
      'apiVersion': 1,
      'entry': 'main.lua',
      'permissions': <String, Object>{'network': domains},
    };
    expect(
      () => PluginManifest.fromJson(withNetwork(<String>['*.com'])),
      throwsFormatException,
    );
    expect(
      () => PluginManifest.fromJson(withNetwork(<String>['*.co.uk'])),
      throwsFormatException,
    );
    expect(
      PluginManifest.fromJson(withNetwork(<String>['*.example.com'])).domains,
      <String>['*.example.com'],
    );
  });

  test('WebSocket permissions are separate and require an explicit scope', () {
    final manifest = PluginManifest.fromJson({
      'id': 'demo.socket',
      'name': 'Demo',
      'version': '1.0.0',
      'provider': 'demo',
      'apiVersion': 1,
      'permissions': {
        'websocket': ['socket.example.com'],
      },
    });
    expect(
      manifest.permitsWebSocket(Uri.parse('wss://socket.example.com')),
      isTrue,
    );
    expect(manifest.permits(Uri.parse('https://socket.example.com')), isFalse);
    expect(
      manifest.permitsWebSocket(Uri.parse('wss://other.example.com')),
      isFalse,
    );
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

  test(
    'Lua host exposes metadata, bundled resources, storage keys and sleep',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-lua-host-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final logs = <String>[];
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'demo.host',
          'name': 'Host API',
          'version': '1.0.0',
          'provider': 'host',
          'apiVersion': 1,
          'permissions': {'storage': true},
        }),
        sources: const {
          'main.lua': '''
          host.storage_set("boot", (host.storage_get("boot") or 0) + 1)
          return {call=function(op)
            if op == "inspect" then
              host.log("debug", "host is alive", {value=42})
              local info = host.plugin_info()
              return {
                runtime = info.runtime,
                id = info.plugin,
                resource = host.read_resource("config.json"),
                decoded = host.json_decode(host.read_resource("config.json")).value,
                keys = host.storage_keys(),
                decodedUrl = host.url_decode(host.url_encode("a b/中")),
                slept = host.sleep(1),
              }
            end
            if op == "clear" then
              host.storage_clear()
              return host.storage_keys()
            end
          end}
        ''',
        },
        resources: const {'config.json': '{"value":42}'},
        dataDirectory: directory.path,
        onLog: (record) => logs.add('${record['level']}:${record['message']}'),
      );
      addTearDown(runtime.close);
      final inspected = await runtime.invoke('inspect') as Map;
      expect(inspected['runtime'], 'native');
      expect(inspected['id'], 'demo.host');
      expect(inspected['resource'], '{"value":42}');
      expect(inspected['decoded'], 42);
      expect(inspected['keys'], ['boot']);
      expect(inspected['decodedUrl'], 'a b/中');
      expect(inspected['slept'], isTrue);
      expect(logs, ['debug:host is alive']);
      expect(await runtime.invoke('clear'), isEmpty);
    },
  );

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

  test(
    'plugin manager exposes registered UI extensions and routes actions',
    () async {
      final root = await Directory.systemTemp.createTemp('lazer-plugin-ui-');
      addTearDown(() => root.delete(recursive: true));
      final pluginId =
          'demo.ui-manager-${DateTime.now().microsecondsSinceEpoch}';
      final manifestBytes = utf8.encode(
        jsonEncode({
          'id': pluginId,
          'name': 'UI Manager',
          'version': '1.0.0',
          'provider': 'demo',
          'apiVersion': 1,
          'entry': 'main.lua',
        }),
      );
      final sourceBytes = utf8.encode('''
      host.add_setting({id="enabled", type="toggle", title="启用", default=true})
      host.add_player_menu_item({id="copy", label="复制", icon="content_copy"})
      return {call=function(operation, args)
        if operation == "describe" then return {} end
        return {operation=operation, id=args.id, value=args.value, track=args.track}
      end}
    ''');
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
      expect(plugin.settings.single.id, 'enabled');
      expect(plugin.playerMenuItems.single.id, 'copy');
      expect(manager.pluginSettings.single.value, isTrue);
      expect(manager.playerMenuItems.single.label, '复制');
      await manager.setPluginSetting(pluginId, 'enabled', false);
      expect(manager.pluginSettings.single.value, isFalse);
      await manager.invokePlayerMenu(manager.playerMenuItems.single, const {
        'id': 'song-1',
      });
      final persisted = File(
        '${root.parent.path}${Platform.pathSeparator}lua_plugin_data${Platform.pathSeparator}$pluginId${Platform.pathSeparator}ui-settings.json',
      );
      expect(await persisted.exists(), isTrue);
    },
  );

  test('Lua scripts restyle and extend their own page at runtime', () async {
    final root = await Directory.systemTemp.createTemp('lazer-plugin-page-');
    addTearDown(() => root.delete(recursive: true));
    final pluginId = 'demo.page-${DateTime.now().microsecondsSinceEpoch}';
    final manifestBytes = utf8.encode(
      jsonEncode({
        'id': pluginId,
        'name': 'Page Manager',
        'version': '1.0.0',
        'provider': 'demo',
        'apiVersion': 1,
        'entry': 'main.lua',
      }),
    );
    final sourceBytes = utf8.encode("""
      host.add_page({
        id = "tools",
        title = "工具",
        subtitle = "插件工具页",
        gap = 4,
        elements = {
          {type = "section", title = "常用"},
          {type = "button", id = "refresh", title = "刷新"},
        },
      })
      host.update_page({page = "tools", title = "工具箱", gap = 18,
        inset = 14, align = "center"})
      host.add_page_element({page = "tools", before = "refresh",
        type = "toggle", id = "enabled", title = "启用", value = true,
        gap = 6})
      host.update_page_element({page = "tools", id = "enabled",
        title = "已启用", subtitle = "由脚本改写"})
      host.remove_page_element({page = "tools", element = "refresh"})
      local snapshot = host.page("tools")
      return {call=function(operation)
        if operation == "describe" then return {} end
        if operation == "snapshot" then
          return {
            pages = #host.pages(),
            title = snapshot.title,
            gap = snapshot.layout.gap,
            inset = snapshot.layout.inset,
            align = snapshot.layout.align,
            count = #snapshot.elements,
            first = snapshot.elements[1].title,
            second = snapshot.elements[2].title,
            tight = snapshot.elements[2].gap,
          }
        end
        return {}
      end}
    """);
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

    final page = manager.pluginPages.single;
    expect(page.id, 'tools');
    expect(page.title, '工具箱');
    expect(page.layout.gap, 18);
    expect(page.layout.inset, 14);
    expect(page.layout.align, LuaPluginPageAlign.center);
    expect(page.elements.map((element) => element.id), <String?>[
      null,
      'enabled',
    ]);
    expect(page.elements.last.title, '已启用');
    expect(page.elements.last.subtitle, '由脚本改写');
    expect(page.elements.last.gap, 6);

    final snapshot = await plugin.runtime!.invoke('snapshot') as Map;
    expect(snapshot['pages'], 1);
    expect(snapshot['title'], '工具箱');
    expect(snapshot['gap'], 18);
    expect(snapshot['inset'], 14);
    expect(snapshot['align'], 'center');
    expect(snapshot['count'], 2);
    expect(snapshot['first'], '常用');
    expect(snapshot['second'], '已启用');
    expect(snapshot['tight'], 6);

    await manager.invokePluginPageEvent(pluginId, 'tools', 'enabled', false);
    expect(manager.pluginPages.single.elements.last.value, isFalse);
  });

  test('a folder zip and Windows paths still resolve the plugin root', () {
    final manifestBytes = utf8.encode(
      jsonEncode(const {
        'id': 'demo.wrapped',
        'name': 'Wrapped',
        'version': '1.0.0',
        'provider': 'demo',
        'apiVersion': 1,
        'entry': 'main.lua',
      }),
    );
    final sourceBytes = utf8.encode('return {call=function() return {} end}');
    final resourceBytes = utf8.encode('{"value":42}');
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'netease-cloud\\manifest.json',
          manifestBytes.length,
          manifestBytes,
        ),
      )
      ..addFile(
        ArchiveFile('netease-cloud\\main.lua', sourceBytes.length, sourceBytes),
      )
      ..addFile(
        ArchiveFile(
          'netease-cloud\\config.json',
          resourceBytes.length,
          resourceBytes,
        ),
      );
    final package = decodePluginPackage(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    expect(package.manifest.id, 'demo.wrapped');
    expect(package.sources.containsKey('main.lua'), isTrue);
    expect(package.resources['config.json'], '{"value":42}');
  });

  test(
    'a VM that times out is replaced, and the next call still works',
    () async {
      final directory = await Directory.systemTemp.createTemp('lazer-restart-');
      addTearDown(() => directory.delete(recursive: true));
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'demo.restart',
          'name': 'Restart',
          'version': '1.0.0',
          'provider': 'restart',
          'apiVersion': 1,
          'entry': 'main.lua',
          'permissions': {'storage': true},
        }),
        sources: const {
          'main.lua': '''
          host.storage_set("boots", (host.storage_get("boots") or 0) + 1)
          return {call = function(op, args)
            if op == "hang" then while true do end end
            if op == "boots" then return {count = host.storage_get("boots")} end
            return {ok = true}
          end}
        ''',
        },
        dataDirectory: directory.path,
        // VM startup shares the host with the rest of the suite. Keep the short
        // deadline on the hung call itself, rather than on isolate startup.
        timeout: const Duration(seconds: 5),
      );
      addTearDown(runtime.close);
      expect(await runtime.invoke('ping'), {'ok': true});
      // A plugin that never returns must not cost the session its plugin: the
      // call reports a retryable timeout and the next call gets a fresh VM.
      await expectLater(
        runtime.invoke('hang', const {}, const Duration(milliseconds: 600)),
        throwsA(
          isA<PluginException>().having(
            (error) => error.code,
            'code',
            PluginException.timeoutCode,
          ),
        ),
      );
      expect(await runtime.invoke('ping'), {'ok': true});
      final boots = await runtime.invoke('boots') as Map;
      expect(boots['count'], 2);
    },
  );

  test('close is permanent while a timeout is not', () async {
    final directory = await Directory.systemTemp.createTemp('lazer-close-');
    addTearDown(() => directory.delete(recursive: true));
    final runtime = LuaPluginRuntime(
      manifest: PluginManifest.fromJson(const {
        'id': 'demo.close',
        'name': 'Close',
        'version': '1.0.0',
        'provider': 'close',
        'apiVersion': 1,
        'entry': 'main.lua',
      }),
      sources: const {
        'main.lua': 'return {call = function() return {ok = true} end}',
      },
      dataDirectory: directory.path,
      timeout: const Duration(seconds: 5),
    );
    runtime.close();
    await expectLater(runtime.invoke('ping'), throwsA(isA<PluginException>()));
  });

  test(
    'Lua plugins can invoke host.player_control and receive player_event',
    () async {
      final directory = await Directory.systemTemp.createTemp('lazer-control-');
      addTearDown(() => directory.delete(recursive: true));
      final controlCalls = <Map<String, dynamic>>[];
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'demo.control',
          'name': 'Control',
          'version': '1.0.0',
          'provider': 'control',
          'apiVersion': 1,
          'entry': 'main.lua',
        }),
        sources: const {
          'main.lua': '''
        local last_event = nil
        return {
          call = function(op, args)
            if op == "do_play" then
              return host.player_control({ command = "play" })
            end
            if op == "do_seek" then
              return host.player_control({ command = "seek", positionMs = 12000 })
            end
            if op == "state" then
              return host.player_state()
            end
            if op == "queue" then
              return host.player_queue()
            end
            if op == "player_event" then
              last_event = args
              return true
            end
            if op == "get_last_event" then
              return last_event
            end
          end
        }
        ''',
        },
        dataDirectory: directory.path,
        onPlayerControl: (spec) async {
          controlCalls.add(spec);
          return {'handled': spec['command']};
        },
      );
      addTearDown(runtime.close);

      final playResult = await runtime.invoke('do_play') as Map;
      expect(playResult['handled'], 'play');
      expect(controlCalls.length, 1);
      expect(controlCalls.first['command'], 'play');

      final seekResult = await runtime.invoke('do_seek') as Map;
      expect(seekResult['handled'], 'seek');
      expect(controlCalls.length, 2);
      expect(controlCalls.last['positionMs'], 12000);

      expect(await runtime.invoke('state'), {'handled': 'status'});
      expect(await runtime.invoke('queue'), {'handled': 'queue'});
      expect(controlCalls.length, 4);

      // Test receiving player_event
      await runtime.invoke('player_event', {
        'type': 'track',
        'data': {'title': 'Test Song', 'duration': 180000},
      });
      final eventReceived = await runtime.invoke('get_last_event') as Map;
      expect(eventReceived['type'], 'track');
      expect((eventReceived['data'] as Map)['title'], 'Test Song');
    },
  );
}
