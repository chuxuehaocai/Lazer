import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';

Future<void> main() async {
  final root = Directory.current;
  final source = Directory('${root.path}/plugins/lazer.netease');
  final output = Directory('${root.path}/dist');
  await output.create(recursive: true);

  final archive = Archive();
  final files = <String>['manifest.json', 'main.lua', 'README.md'];
  for (final name in files) {
    final file = File('${source.path}/$name');
    if (!await file.exists()) {
      throw FileSystemException('Missing Lua plugin source', file.path);
    }
    final bytes = await file.readAsBytes();
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  final bytes = ZipEncoder().encode(archive);
  final manifest =
      jsonDecode(await File('${source.path}/manifest.json').readAsString())
          as Map;
  final target = File(
    '${output.path}/${manifest['id']}-${manifest['version']}.zip',
  );
  await target.writeAsBytes(bytes, flush: true);
  stdout.writeln('Built ${target.path} (${bytes.length} bytes)');
}
