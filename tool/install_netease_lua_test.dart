import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';

const _zipPath = String.fromEnvironment('LAZER_NETEASE_PLUGIN_ZIP');
const _pluginRoot = String.fromEnvironment('LAZER_NETEASE_PLUGIN_ROOT');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'imports and starts the packaged NetEase Lua plugin in the requested app directory',
    () async {
      final manager = PluginManager(rootDirectory: Directory(_pluginRoot));
      try {
        final plugin = await manager.importZip(
          await File(_zipPath).readAsBytes(),
        );
        expect(plugin.manifest.id, 'lazer.netease');
        expect(plugin.manifest.version, '1.0.3');
        expect(plugin.error, isNull);
        expect(manager.gateways.single.provider.id, 'netease');
        final description = await plugin.runtime!.invoke('describe');
        expect(description, isA<Map>());
        // The manager owns the runtime on success; the process exit ends it.
        stdout.writeln('Installed and started ${plugin.manifest.name}');
      } finally {
        manager.dispose();
      }
    },
    skip: _zipPath.isEmpty || _pluginRoot.isEmpty,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
