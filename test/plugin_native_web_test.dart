@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'web Lua native host reports unsupported without loading native libraries',
    () async {
      SharedPreferences.setMockInitialValues({});
      final archive = Archive();
      for (final entry in {
        'manifest.json': jsonEncode({
          'id': 'fixture.web-native',
          'name': 'Web native',
          'version': '1.0.0',
          'provider': 'webnative',
          'apiVersion': 1,
          'permissions': {
            'data': ['native_audio', 'native_control'],
          },
        }),
        'main.lua': '''
return {call=function(operation,args)
  if operation == "describe" then return {providers={}} end
  return host.native(args)
end}
''',
      }.entries) {
        final bytes = utf8.encode(entry.value);
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      final manager = PluginManager();
      final state = AppState(
        pluginManager: manager,
        artworkSeedLoader: (_) async => null,
      );
      addTearDown(() async {
        state.dispose();
        await manager.shutdownSettled;
      });
      final prompts = <String>[];
      manager.onPermissionRequest = (_, permission) async {
        prompts.add(permission);
        return true;
      };
      final plugin = await manager.importZip(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
      final runtime = plugin.runtime!;
      final capabilities = await runtime.invoke('native') as Map;
      expect(capabilities['platform'], 'web');
      expect(
        (capabilities['operations'] as Map).values.every(
          (item) => (item as Map)['supported'] == false,
        ),
        true,
      );
      expect(prompts, isEmpty);
      for (final operation in [
        'audio.status',
        'audio.devices',
        'lyrics.status',
        'lyrics.configure',
      ]) {
        final result =
            await runtime.invoke('native', {
                  'operation': operation,
                  if (operation == 'lyrics.configure') 'mode': 'floating',
                })
                as Map;
        expect(result['ok'], false);
        expect(result['supported'], false);
      }
      expect(prompts, ['data.native_audio', 'data.native_control']);
      expect(state.floatingLyricsEnabled, false);
    },
  );
}
