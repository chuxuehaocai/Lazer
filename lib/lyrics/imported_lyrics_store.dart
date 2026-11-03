import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import '../storage/app_storage.dart';

import '../data/models.dart';
import 'lyric_document.dart';

/// Decodes `.lrc` bytes. UTF-8 (with or without BOM) and UTF-16 with a BOM are
/// accepted; other encodings raise [FormatException] so the UI can ask for
/// UTF-8 instead of silently showing mojibake.
String decodeLyricsBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes.sublist(2), little: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes.sublist(2), little: false);
  }
  return utf8.decode(bytes);
}

String _utf16(List<int> bytes, {required bool little}) {
  final List<int> units = <int>[];
  for (int index = 0; index + 1 < bytes.length; index += 2) {
    units.add(
      little
          ? bytes[index] | (bytes[index + 1] << 8)
          : (bytes[index] << 8) | bytes[index + 1],
    );
  }
  return String.fromCharCodes(units);
}

/// User-imported lyrics, keyed by track id.
///
/// They take priority over the service and over a `.lrc` next to a local file,
/// so an imported translation keeps working while the cloud copy changes.
class ImportedLyricsStore {
  ImportedLyricsStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? appSupportDirectory;

  static const String _folder = 'imported_lyrics';
  final Future<Directory> Function() _supportDirectory;
  Future<Directory?>? _root;

  Future<Directory?> _directory() => _root ??= () async {
    try {
      final Directory support = await _supportDirectory();
      final Directory directory = Directory(
        '${support.path}${Platform.pathSeparator}$_folder',
      );
      await directory.create(recursive: true);
      return directory;
    } catch (_) {
      return null;
    }
  }();

  Future<File?> fileFor(Track track) async {
    if (track.id.isEmpty) return null;
    final Directory? directory = await _directory();
    if (directory == null) return null;
    final String name = sha1.convert(utf8.encode(track.id)).toString();
    return File('${directory.path}${Platform.pathSeparator}$name.lrc');
  }

  Future<bool> has(Track track) async {
    final File? file = await fileFor(track);
    try {
      return file != null && await file.exists();
    } catch (_) {
      return false;
    }
  }

  Future<String?> read(Track track) async {
    final File? file = await fileFor(track);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final String text = decodeLyricsBytes(await file.readAsBytes());
      return parseLrc(text).isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Saves [content] only when it contains at least one timed line.
  Future<bool> save(Track track, String content) async {
    if (parseLrc(content).isEmpty) return false;
    final File? file = await fileFor(track);
    if (file == null) return false;
    try {
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(Track track) async {
    final File? file = await fileFor(track);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// A `.lrc` beside a downloaded or scanned file, used when the service has
  /// no lyrics and the user has not imported any.
  static Future<String?> sidecarFor(String? audioPath) async {
    if (audioPath == null || audioPath.isEmpty) return null;
    final int dot = audioPath.lastIndexOf('.');
    final String stem = dot > 0 ? audioPath.substring(0, dot) : audioPath;
    for (final String extension in <String>['.lrc', '.LRC', '.Lrc']) {
      try {
        final File file = File('$stem$extension');
        if (!await file.exists()) continue;
        final Uint8List bytes = await file.readAsBytes();
        final String text = decodeLyricsBytes(bytes);
        return parseLrc(text).isEmpty ? null : text;
      } catch (_) {}
    }
    return null;
  }
}
