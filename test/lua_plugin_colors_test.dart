import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_colors.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fixture plugin for the palette contract.
///
/// Every palette call is wrapped in `pcall` so the assertions read the message
/// the plugin itself would catch, instead of losing it to the runtime's outer
/// error path.
const String _paletteSource = '''
local function attempt(call)
  local ok, result = pcall(call)
  if not ok then return { rejected = tostring(result) } end
  return result
end

return {
  call = function(operation, args)
    if operation == "describe" then return {} end
    if operation == "info" then return host.info() end
    if operation == "read" then
      return attempt(function() return host.colors() end)
    end
    if operation == "write" then
      return attempt(function() return host.set_colors(args.value) end)
    end
  end
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<LuaPluginRuntime> start(
    Directory directory, {
    required bool appearance,
    required Future<Object?> Function(Map<String, dynamic> spec) onColors,
  }) async {
    final runtime = LuaPluginRuntime(
      manifest: PluginManifest.fromJson({
        'id': 'demo.palette',
        'name': 'Palette',
        'version': '1.0.0',
        'provider': 'palette',
        'apiVersion': 1,
        'entry': 'main.lua',
        'permissions': <String, Object>{if (appearance) 'appearance': true},
      }),
      sources: const {'main.lua': _paletteSource},
      dataDirectory: directory.path,
      onColors: onColors,
    );
    addTearDown(runtime.close);
    await runtime.start();
    return runtime;
  }

  test(
    'a plugin without the appearance permission is rejected and the palette '
    'is untouched',
    () async {
      final directory = await Directory.systemTemp.createTemp('lazer-palette-');
      addTearDown(() => directory.delete(recursive: true));
      final state = AppState();
      addTearDown(state.dispose);
      var calls = 0;
      final runtime = await start(
        directory,
        appearance: false,
        onColors: (spec) {
          calls++;
          return state.pluginManager.onColors!(spec);
        },
      );

      final read = await runtime.invoke('read') as Map;
      expect(read['rejected'], contains('Appearance permission required'));
      final write = await runtime.invoke('write', {
        'value': {'accent': '#3366CC'},
      }) as Map;
      expect(write['rejected'], contains('Appearance permission required'));

      // The gate runs inside the VM, so the host handler never saw a request
      // and the listener's palette kept the shipped accent.
      expect(calls, 0);
      expect(state.paletteMode, AppPaletteMode.fixed);
      expect(state.accentColor, isNull);
      expect(state.accentSeed, isNull);
    },
  );

  test('the appearance permission applies accent and mode through AppState', () async {
    final directory = await Directory.systemTemp.createTemp('lazer-palette-');
    addTearDown(() => directory.delete(recursive: true));
    final state = AppState();
    addTearDown(state.dispose);
    final runtime = await start(
      directory,
      appearance: true,
      onColors: (spec) => state.pluginManager.onColors!(spec),
    );

    // Supplying only an accent implies `custom`, which is what the plugin reads
    // back with the normalised colour spelling.
    final accent = await runtime.invoke('write', {
      'value': {'accent': '#3366CC'},
    });
    expect(accent, {'ok': true, 'mode': 'custom', 'accent': '#3366CC'});
    expect(state.paletteMode, AppPaletteMode.custom);
    expect(state.accentColor, const Color(0xFF3366CC));
    expect(state.accentSeed, const Color(0xFF3366CC));
    expect(await runtime.invoke('read'), {
      'ok': true,
      'mode': 'custom',
      'accent': '#3366CC',
    });

    // A mode-only request keeps the stored accent but stops painting it.
    final following = await runtime.invoke('write', {
      'value': {'mode': 'nowPlaying'},
    });
    expect(following, {'ok': true, 'mode': 'nowPlaying'});
    expect(state.paletteMode, AppPaletteMode.nowPlaying);
    expect(state.accentColor, const Color(0xFF3366CC));

    // `fixed` is "ignore the custom accent", not "erase the listener's colour":
    // AppState cannot clear it, and accentSeed already discards it.
    final fixed = await runtime.invoke('write', {
      'value': {'mode': 'fixed'},
    });
    expect(fixed, {'ok': true, 'mode': 'fixed'});
    expect(state.paletteMode, AppPaletteMode.fixed);
    expect(state.accentColor, const Color(0xFF3366CC));
    expect(state.accentSeed, isNull);
  });

  test('invalid palette input is rejected without touching the palette', () async {
    final directory = await Directory.systemTemp.createTemp('lazer-palette-');
    addTearDown(() => directory.delete(recursive: true));
    final state = AppState();
    addTearDown(state.dispose);
    final runtime = await start(
      directory,
      appearance: true,
      onColors: (spec) => state.pluginManager.onColors!(spec),
    );

    expect(await runtime.invoke('write', {
      'value': {'accent': '#112233'},
    }), {'ok': true, 'mode': 'custom', 'accent': '#112233'});

    const invalid = <String, Object?>{
      'bare hex accent': {'accent': '112233'},
      'short hex accent': {'accent': '#11223'},
      'long hex accent': {'accent': '#1122334'},
      'non hex accent': {'accent': '#GGGGGG'},
      'unknown mode': {'mode': 'dark'},
      'numeric mode': {'mode': 3},
      'extra key': {'accent': '#445566', 'brightness': 'dark'},
      'accent with ignored mode': {'accent': '#445566', 'mode': 'fixed'},
      'string argument': 'nope',
      'number argument': 42,
    };
    for (final entry in invalid.entries) {
      final reply = await runtime.invoke('write', {
        'value': entry.value,
      }) as Map;
      expect(
        reply['rejected'],
        isA<String>(),
        reason: '${entry.key} must be rejected',
      );
      expect(
        state.paletteMode,
        AppPaletteMode.custom,
        reason: '${entry.key} changed the mode',
      );
      expect(
        state.accentColor,
        const Color(0xFF112233),
        reason: '${entry.key} changed the accent',
      );
    }
  });

  test('the host handler maps palette modes without a Lua VM', () async {
    final state = AppState();
    addTearDown(state.dispose);
    final colors = state.pluginManager.onColors!;

    expect(await colors(PluginColors.query), {'ok': true, 'mode': 'fixed'});
    // The runtime forwards `PluginColors.request(...)`, so this is the exact
    // hand-off the handler sees for `host.set_colors{accent = "#204060"}`.
    expect(await colors(PluginColors.request({'accent': '#204060'})), {
      'ok': true,
      'mode': 'custom',
      'accent': '#204060',
    });
    expect(await colors({'command': 'set', 'mode': 'nowPlaying'}), {
      'ok': true,
      'mode': 'nowPlaying',
    });
    expect(await colors({'command': 'set', 'mode': 'custom'}), {
      'ok': true,
      'mode': 'custom',
      'accent': '#204060',
    });
    expect(state.paletteMode, AppPaletteMode.custom);
    expect(state.accentColor, const Color(0xFF204060));
  });

  test('the palette contract normalises requests and formats responses', () {
    expect(PluginColors.request(null), {'command': 'set'});
    expect(PluginColors.request(<String, Object>{}), {'command': 'set'});
    expect(PluginColors.request({'accent': '#a1b2c3'}), {
      'command': 'set',
      'mode': 'custom',
      'accent': 0xFFA1B2C3,
    });
    expect(PluginColors.request({'mode': 'nowPlaying'}), {
      'command': 'set',
      'mode': 'nowPlaying',
    });
    expect(PluginColors.response('custom', 0xFF0A0B0C), {
      'ok': true,
      'mode': 'custom',
      'accent': '#0A0B0C',
    });
    expect(PluginColors.response('fixed', null), {'ok': true, 'mode': 'fixed'});
    // A conflict is a plugin bug: the colour would be discarded, so it is an
    // error instead of a silent no-op.
    expect(
      () => PluginColors.request({'mode': 'fixed', 'accent': '#000000'}),
      throwsFormatException,
    );
    expect(
      () => PluginColors.request({'mode': 'custom', 'extra': true}),
      throwsFormatException,
    );
  });

  test('the manifest parses appearance and advertises it to the host', () async {
    Map<String, dynamic> manifestJson(Map<String, Object>? permissions) => {
      'id': 'demo.palette',
      'name': 'Palette',
      'version': '1.0.0',
      'provider': 'palette',
      'apiVersion': 1,
      'entry': 'main.lua',
      'permissions': ?permissions,
    };

    final granted = PluginManifest.fromJson(
      manifestJson({'appearance': true}),
    );
    expect(granted.appearance, isTrue);
    expect(PluginManifest.fromJson(granted.toJson()).appearance, isTrue);
    expect(PluginManifest.fromJson(manifestJson(null)).appearance, isFalse);
    // Only an explicit `true` grants it, exactly like `storage`.
    expect(
      PluginManifest.fromJson(manifestJson({'appearance': 'yes'})).appearance,
      isFalse,
    );

    final directory = await Directory.systemTemp.createTemp('lazer-palette-');
    addTearDown(() => directory.delete(recursive: true));
    final runtime = await start(
      directory,
      appearance: true,
      onColors: _noColorHost,
    );
    final info = await runtime.invoke('info') as Map;
    expect((info['permissions'] as Map)['appearance'], isTrue);
    expect(info['features'], contains('appearance'));
  });

  test('the manager wires the palette callback only for a declared '
      'appearance permission', () async {
    final root = await Directory.systemTemp.createTemp('lazer-palette-');
    addTearDown(() => root.delete(recursive: true));
    final manager = PluginManager(rootDirectory: root);
    addTearDown(manager.dispose);
    final seen = <Map<String, dynamic>>[];
    manager.onColors = (spec) async {
      seen.add(spec);
      return PluginColors.response('custom', spec['accent'] as int?);
    };

    Future<InstalledPlugin> install(String id, {required bool appearance}) {
      final manifest = utf8.encode(
        jsonEncode({
          'id': id,
          'name': 'Palette $id',
          'version': '1.0.0',
          'provider': 'palette',
          'apiVersion': 1,
          'entry': 'main.lua',
          'capabilities': const <String>[],
          'permissions': <String, Object>{if (appearance) 'appearance': true},
        }),
      );
      final source = utf8.encode(_paletteSource);
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', manifest.length, manifest),
        )
        ..addFile(ArchiveFile('main.lua', source.length, source));
      return manager.importZip(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
    }

    final denied = await install('lazer.palette.denied', appearance: false);
    expect(await (denied.runtime!).invoke('write', {
      'value': {'accent': '#3366CC'},
    }), containsPair('rejected', contains('Appearance permission required')));
    expect(seen, isEmpty);

    final allowed = await install('lazer.palette.allowed', appearance: true);
    expect(await (allowed.runtime!).invoke('write', {
      'value': {'accent': '#3366CC'},
    }), {'ok': true, 'mode': 'custom', 'accent': '#3366CC'});
    expect(seen, [
      {'command': 'set', 'mode': 'custom', 'accent': 0xFF3366CC},
    ]);
  });
}

/// A host that accepts palette calls and reports the shipped accent.
Future<Object?> _noColorHost(Map<String, dynamic> spec) async =>
    PluginColors.response('fixed', null);
