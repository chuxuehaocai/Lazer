import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;

import 'app_storage.dart';

/// Listening history lives outside preferences and removable caches. Flush the
/// temporary file before atomically replacing the previous complete snapshot.
class ListeningStatisticsStore {
  ListeningStatisticsStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? appSupportDirectory;

  static const fileName = 'listening_statistics_v1.json';
  final Future<Directory> Function() _supportDirectory;

  Future<String?> read() async {
    final directory = await _supportDirectory();
    final file = File('${directory.path}/$fileName');
    return await file.exists() ? file.readAsString() : null;
  }

  Future<void> write(String raw) async {
    final directory = await _supportDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}/$fileName');
    final temporary = File('${file.path}.tmp');
    final List<int> bytes = raw.length < 262144
        ? utf8.encode(raw)
        : await compute(
            _encodeSnapshot,
            raw,
            debugLabel: 'listening-statistics-write',
          );
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
}

List<int> _encodeSnapshot(String raw) => utf8.encode(raw);
