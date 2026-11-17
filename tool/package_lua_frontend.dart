import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Run from the repository root: dart run tool/package_lua_frontend.dart
Future<void> main(List<String> args) async {
  final root = Directory('examples/lua-frontend');
  final archive = Archive();
  await for (final file in root.list(recursive: true, followLinks: false)) {
    if (file is! File) continue;
    final bytes = await file.readAsBytes();
    archive.addFile(
      ArchiveFile(
        p.relative(file.path, from: root.path).replaceAll(r'\', '/'),
        bytes.length,
        bytes,
      ),
    );
  }
  final output = File(
    args.isEmpty ? 'build/lua-frontend-example.zip' : args.single,
  );
  await output.parent.create(recursive: true);
  await output.writeAsBytes(ZipEncoder().encode(archive));
  stdout.writeln(output.absolute.path);
}
