import 'dart:io';

import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

/// Runs real, read-only requests outside Flutter's test HTTP overrides.
/// An optional session file is copied into disposable isolated storage.
Future<void> main(List<String> args) async {
  final data = await Directory.systemTemp.createTemp('netease-live-smoke-');
  final source = Directory('plugins/lazer.netease');
  if (args.isNotEmpty) {
    await File(args.single).copy('${data.path}/storage.json');
  }
  final runtime = LuaPluginRuntime(
    manifest: PluginManifest.decode(
      await File('${source.path}/manifest.json').readAsString(),
    ),
    sources: {'main.lua': await File('${source.path}/main.lua').readAsString()},
    dataDirectory: data.path,
  );
  try {
    final search =
        await runtime.invoke('search', {'query': 'mizuiro', 'limit': 2}) as Map;
    stdout.writeln('Public search: ${(search['songs'] as List).length} songs');
    final lyrics = await runtime.invoke('lyrics', {'id': '33894312'}) as List;
    stdout.writeln('Public lyrics: ${lyrics.length} versions');
    final comments =
        await runtime.invoke('comments', {'id': '33894312', 'limit': 2}) as Map;
    stdout.writeln(
      'Public comments: ${(comments['latest'] as List).length} rows',
    );
    if (args.isNotEmpty) {
      final session = await runtime.invoke('session');
      if (session == null) throw StateError('Session is not authenticated');
      for (final operation in ['favorites', 'playlists', 'savedAlbums']) {
        final result = await runtime.invoke(operation, {'limit': 2}) as List;
        stdout.writeln('Account $operation: ${result.length} rows');
      }
    }
  } finally {
    runtime.close();
    await data.delete(recursive: true);
  }
}
