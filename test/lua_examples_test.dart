// Guards the examples/ folder: both projects must stay installable, which is
// what the plugin manager checks when a user imports the built ZIP.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/plugins/plugin_manager.dart';

/// Packs a folder the way examples/build.bat and build.sh do: every file keeps
/// its relative path and `manifest.json` ends up at the archive root.
Future<Uint8List> _package(String directory) async {
  final root = Directory(directory);
  final archive = Archive();
  await for (final entry in root.list(recursive: true, followLinks: false)) {
    if (entry is! File) continue;
    final bytes = await entry.readAsBytes();
    final name = entry.path
        .substring(root.path.length + 1)
        .replaceAll(r'\', '/');
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late PluginManager plugins;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lazer-example-');
    plugins = PluginManager(
      rootDirectory: Directory('${root.path}/plugins'),
    );
  });

  tearDown(() async {
    plugins.dispose();
    await plugins.shutdownSettled;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('both bundled examples import without an error', () async {
    final gateway = await plugins.importZip(
      await _package('examples/gateway-mock'),
    );
    expect(gateway.error, isNull);
    expect(gateway.manifest.id, 'example.gateway-mock');
    expect(plugins.gateways.map((item) => item.provider.id), contains('mockwave'));

    final theme = await plugins.importZip(
      await _package('examples/theme-plugin'),
    );
    expect(theme.error, isNull);
    expect(theme.manifest.id, 'example.theme-atelier');
    expect(theme.theme, isNotNull);
  });
}
