import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/plugin_manager_io.dart';

/// Records the last `player_event` payload the host handed to the VM.
///
/// `last_event` reports what the plugin actually received, so a plugin that the
/// host skips keeps answering `received = false`.
const String _recorderSource = '''
local last = nil
return {
  call = function(operation, args)
    if operation == "describe" then
      return {}
    end
    if operation == "player_event" then
      last = args
      return true
    end
    if operation == "last_event" then
      if last == nil then
        return {received = false}
      end
      return {received = true, type = last.type, data = last.data}
    end
    return {received = false}
  end
}
''';

void main() {
  test('PluginManager only broadcasts player_event to plugins declaring '
      'player_events capability', () async {
    final root = await Directory.systemTemp.createTemp('lazer-pe-test-');
    addTearDown(() => root.delete(recursive: true));

    final manager = PluginManager(rootDirectory: root);
    addTearDown(manager.dispose);

    Future<InstalledPlugin> install({
      required String id,
      required String provider,
      required List<String> capabilities,
    }) async {
      final manifestBytes = utf8.encode(
        jsonEncode({
          'id': id,
          'name': 'Mock $provider',
          'version': '1.0.0',
          'provider': provider,
          'apiVersion': 1,
          'entry': 'main.lua',
          'capabilities': capabilities,
        }),
      );
      final sourceBytes = utf8.encode(_recorderSource);
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(ArchiveFile('main.lua', sourceBytes.length, sourceBytes));
      return manager.importZip(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
    }

    // Nothing installed yet: no listener to broadcast to.
    expect(manager.hasPlayerEventListeners, isFalse);

    // A music source without the capability still owns a running VM, so
    // liveliness cannot be what selects a listener.
    final source = await install(
      id: 'lazer.netease.mock',
      provider: 'netease',
      capabilities: const ['search', 'lyrics'],
    );
    expect(source.runtime, isNotNull);
    expect(manager.hasPlayerEventListeners, isFalse);

    // A bridge plugin that declares the capability joins the broadcast.
    final bridge = await install(
      id: 'lazer.ws.mock',
      provider: 'ws_bridge',
      capabilities: const ['player_events'],
    );
    expect(bridge.runtime, isNotNull);
    expect(manager.hasPlayerEventListeners, isTrue);

    manager.broadcastPlayerEvent('track', const {
      'title': 'Test Song',
      'duration': 180000,
    });

    // The runtime serialises every call on one queue, so this probe resolves
    // after the broadcast queued ahead of it has been handled or skipped.
    final delivered = await bridge.runtime!.invoke('last_event') as Map;
    expect(delivered['received'], isTrue);
    expect(delivered['type'], 'track');
    expect((delivered['data'] as Map)['title'], 'Test Song');

    final skipped = await source.runtime!.invoke('last_event') as Map;
    expect(skipped['received'], isFalse);

    // A live VM is not enough either: disabling the bridge parks its runtime
    // but the capability check still has to exclude it.
    bridge.enabled = false;
    expect(manager.hasPlayerEventListeners, isFalse);
  });
}
