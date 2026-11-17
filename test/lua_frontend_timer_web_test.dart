@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime_web.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

void main() {
  test(
    'web timer waits for actual VM work beyond caller-facing timeout',
    () async {
      final gate = Completer<Object?>();
      final entered = Completer<void>();
      var ticks = 0;
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson({
          'id': 'fixture.webtimer',
          'name': 'Timer',
          'version': '1.0.0',
          'provider': 'timer',
          'apiVersion': 1,
        }),
        sources: const {
          'main.lua': '''
host.timer({id="slow", intervalMs=100})
return {call=function(operation,args)
  if operation == "timer" then return host.player_state() end
  if operation == "cancel" then return host.timer({operation="cancel",id="slow"}) end
end}
''',
        },
        dataDirectory: 'web-timer-test',
        timeout: const Duration(milliseconds: 40),
        onPlayerControl: (_) {
          ticks++;
          if (!entered.isCompleted) entered.complete();
          return gate.future;
        },
      );
      addTearDown(runtime.close);
      await runtime.start();
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      gate.complete(true);
      // A timer based on invoke().timeout would have queued three more calls;
      // this cancel goes behind them and exposes that backlog deterministically.
      await runtime.invoke('cancel');
      expect(ticks, 1);
      await runtime.shutdown();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(ticks, 1);
    },
  );
}
