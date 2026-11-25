// Gateway plugins reach the host through Lua, not the other way round: a plugin
// calls `pcall`, `host.http`, `host.add_setting` … and expects the answer back
// inside the same Lua closure. The published `lua_dardo_plus` runs a Lua closure
// synchronously, so those nested async calls only work with the compatibility
// patch in `tool/patch_lua_dardo_plus.dart` applied to the resolved package.
//
// Without this test a checkout that skipped the patch fails much later, in a
// published plugin, as "插件启动失败" with no Lua line to look at.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

const _source = '''
local calls = 0

-- Reached through the host's async `pcall`, from inside a Lua closure, and it
-- reads an async-hosted value while doing so: three nested calls that only
-- resolve when the VM awaits the host answer before continuing the closure.
local function probe()
  calls = calls + 1
  local now = host.now()
  return type(now) == "number" and now > 0
end

local hosted, hostedValue = pcall(probe)
local guarded, guardedMessage = pcall(function() error("boom", 0) end)

return {
  call = function(operation)
    if operation == "describe" then return { providers = {} } end
    return {
      calls = calls,
      hosted = hosted,
      hostedValue = hostedValue,
      guarded = guarded,
      guardedMessage = tostring(guardedMessage),
    }
  end,
}
''';

PluginManifest _manifest() => PluginManifest.fromJson(const {
  'id': 'demo.async-host',
  'name': 'Async host calls',
  'version': '1.0.0',
  'provider': 'demo',
  'apiVersion': 1,
  'entry': 'main.lua',
});

void main() {
  test('Lua reaches async host calls and recovers from a protected error',
      () async {
    final directory = await Directory.systemTemp.createTemp('lua-async-host');
    addTearDown(() => directory.delete(recursive: true));
    final runtime = LuaPluginRuntime(
      manifest: _manifest(),
      sources: const {'main.lua': _source},
      dataDirectory: directory.path,
      timeout: const Duration(seconds: 20),
    );
    addTearDown(runtime.close);

    await runtime.start();
    final result = Map<String, dynamic>.from(
      await runtime.invoke('run') as Map,
    );

    expect(result['hosted'], isTrue, reason: 'pcall reached the async host');
    expect(result['hostedValue'], isTrue, reason: 'host.now answered in Lua');
    expect(result['calls'], 1, reason: 'the closure ran exactly once');
    expect(result['guarded'], isFalse, reason: 'the error was protected');
    expect('${result['guardedMessage']}', contains('boom'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
