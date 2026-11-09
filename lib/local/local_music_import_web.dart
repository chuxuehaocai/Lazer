import 'dart:html' as html;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../data/models.dart';
import 'local_library_web.dart';

const List<String> localAudioExtensions = <String>[
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'oga',
  'opus',
  'wav',
  'wave',
  'mp4',
];

const XTypeGroup localAudioTypeGroup = XTypeGroup(
  label: '本地音乐',
  extensions: localAudioExtensions,
  mimeTypes: <String>['audio/*'],
  uniformTypeIdentifiers: <String>['public.audio'],
);

typedef LocalAudioFilePicker = Future<List<String>> Function();

Future<List<String>> openLocalAudioPicker() async {
  final List<XFile> files = await openFiles(
    acceptedTypeGroups: const <XTypeGroup>[localAudioTypeGroup],
  );
  return <String>[for (final XFile file in files) file.name];
}

class LocalImportResult {
  const LocalImportResult({this.added = 0, this.skipped = 0, this.failed = 0});

  static const LocalImportResult empty = LocalImportResult();

  final int added;
  final int skipped;
  final int failed;

  int get total => added + skipped + failed;
  bool get isEmpty => total == 0;
}

class LocalImportException implements Exception {
  const LocalImportException(this.message);

  final String message;

  @override
  String toString() => 'LocalImportException: $message';
}

/// Browser importer: the chooser hands back file contents, which are stored in
/// IndexedDB and played through an object URL.
class LocalMusicImporter {
  const LocalMusicImporter({Object? probe, LocalAudioFilePicker? picker});

  // Kept for API parity with the native importer; the browser reads files
  // directly instead of reopening paths.
  static LocalAudioFilePicker get picker => openLocalAudioPicker;

  Future<List<html.File>> _pickFiles() async {
    final input = html.FileUploadInputElement()
      ..multiple = true
      ..accept = 'audio/*';
    input.click();
    await input.onChange.first;
    final files = input.files;
    return files == null ? const <html.File>[] : files.toList();
  }

  Future<Uint8List> _read(html.File file) async {
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoadEnd.first;
    final result = reader.result;
    if (result is Uint8List) return result;
    if (result is ByteBuffer) return Uint8List.view(result);
    if (result is ByteData) {
      return result.buffer.asUint8List(
        result.offsetInBytes,
        result.lengthInBytes,
      );
    }
    throw FormatException('无法读取 ${file.name}');
  }

  Future<LocalImportResult> importInto(LocalLibrary library) async {
    // The browser chooser returns the files themselves; there are no paths
    // to reopen, so the picker is consulted exactly once.
    final List<html.File> files;
    try {
      files = await _pickFiles();
    } catch (_) {
      throw const LocalImportException('无法打开文件选择器，请检查系统权限后重试。');
    }
    if (files.isEmpty) return LocalImportResult.empty;
    await library.load();
    var added = 0;
    var skipped = 0;
    var failed = 0;
    final entries = <LocalTrack>[];
    for (final file in files) {
      try {
        final Uint8List bytes = await _read(file);
        if (bytes.isEmpty) {
          failed++;
          continue;
        }
        final id = localTrackIdForPath('${file.name}:${bytes.length}');
        await LocalBlobStore.instance.put(id, bytes);
        final title = _titleOf(file.name);
        final entry = LocalTrack(
          track: Track(
            id: id,
            title: title,
            artist: '本地音乐',
            album: '',
            duration: Duration.zero,
            coverSeed: id.hashCode,
            localPath: id,
          ),
          path: id,
          source: LocalTrackSource.scan,
          modifiedAt: DateTime.now(),
          addedAt: DateTime.now(),
          bytes: bytes.length,
        );
        if (library.entryForPath(id) != null) {
          skipped++;
        } else {
          added++;
        }
        entries.add(entry);
      } catch (_) {
        failed++;
      }
    }
    if (entries.isNotEmpty) await library.addTracks(entries);
    return LocalImportResult(added: added, skipped: skipped, failed: failed);
  }

  Future<LocalImportResult> addPaths(
    LocalLibrary library,
    Iterable<String> paths,
  ) async => const LocalImportResult(failed: 1);

  String _titleOf(String name) {
    final slash = name.replaceAll('\\', '/');
    final base = slash.split('/').last;
    final dot = base.lastIndexOf('.');
    final title = dot > 0 ? base.substring(0, dot) : base;
    return title.trim().isEmpty ? '未命名' : title.trim();
  }
}
