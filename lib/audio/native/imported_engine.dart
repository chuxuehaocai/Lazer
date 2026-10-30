import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import 'lazer_audio_library.dart';

Future<String?> importAudioEngine() async {
  final List<XFile> files = await openFiles(
    acceptedTypeGroups: Platform.isAndroid
        ? const []
        : [
            XTypeGroup(
              label: 'Audio Engine',
              extensions: [
                if (Platform.isWindows)
                  'dll'
                else if (Platform.isMacOS)
                  'dylib'
                else
                  'so',
              ],
            ),
          ],
  );
  if (files.isEmpty) return null;
  final String extension = Platform.isWindows
      ? '.dll'
      : Platform.isMacOS
      ? '.dylib'
      : '.so';
  final List<XFile> engines = files
      .where(
        (file) =>
            files.length == 1 ||
            file.name.toLowerCase() == 'lazer-audio$extension' ||
            file.name.toLowerCase() == 'liblazer-audio$extension',
      )
      .toList();
  if (engines.length != 1) {
    throw const FormatException('请选择一个 lazer-audio 引擎文件，可同时选择依赖库');
  }
  final Directory support = await getApplicationSupportDirectory();
  final Directory directory = Directory(
    '${support.path}/audio-engines/${DateTime.now().microsecondsSinceEpoch}',
  );
  await directory.create(recursive: true);
  bool retained = false;
  try {
    for (final file in files) {
      if (file.name.contains('/') || file.name.contains('\\')) {
        throw const FormatException('无效的引擎文件名');
      }
      await file.saveTo('${directory.path}/${file.name}');
    }
    final String path = '${directory.path}/${engines.single.name}';
    final String? error = await Isolate.run(
      () => LazerAudioLoader.inspect(path).reason,
    );
    if (error != null) throw FormatException(error);
    retained = true;
    return path;
  } finally {
    if (!retained) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        /* Windows may keep a rejected library mapped until exit. */
      }
    }
  }
}
