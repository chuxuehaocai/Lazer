import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import '../storage/app_storage.dart';

/// Image formats the backdrop can decode, shared by the picker filter and the
/// extension keeper.
const List<String> _backgroundImageExtensions = <String>[
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'gif',
];

const XTypeGroup _imageTypeGroup = XTypeGroup(
  label: '图片',
  extensions: _backgroundImageExtensions,
  // Android's picker filters by MIME type; desktop platforms use extensions.
  mimeTypes: <String>[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/bmp',
    'image/gif',
  ],
  // iOS rejects a type group without uniform type identifiers (the picker
  // throws before it ever opens). `public.image` covers every format above.
  uniformTypeIdentifiers: <String>['public.image'],
);

/// Prefix of the copies this app keeps; also how [BackgroundImageStore]
/// recognises files it may remove.
const String _filePrefix = 'background_';

/// Copies picked pictures into the app's own directory and resolves stored
/// preferences against the current app container.
///
/// The preference holds only the file name. iOS can change the sandbox
/// container path between launches; an absolute path then points at nothing
/// even though the file still exists in the new container. Keeping the name
/// and resolving it through `appSupportDirectory` makes the
/// backdrop survive a relaunch, an update or the app being killed.
class BackgroundImageStore {
  BackgroundImageStore({Future<Directory> Function()? directory})
    : _directory = directory ?? appSupportDirectory;

  final Future<Directory> Function() _directory;

  /// Writes [bytes] under a fresh, timestamped name. The timestamp also
  /// defeats Flutter's image cache, so replacing a picture always repaints.
  Future<String> write(Uint8List bytes, {required String sourceName}) async {
    final Directory directory = await _directory();
    final String target =
        '${directory.path}${Platform.pathSeparator}$_filePrefix'
        '${DateTime.now().microsecondsSinceEpoch}'
        '${_extensionOf(sourceName)}';
    await File(target).writeAsBytes(bytes, flush: true);
    return target;
  }

  /// The value worth persisting for [path]. App-owned copies are stored as
  /// just their name; foreign paths are left untouched so a caller cannot
  /// accidentally point the preference at a file this app may not delete.
  String preferenceValue(String path) {
    final String name = _baseName(path);
    return name.startsWith(_filePrefix) ? name : path;
  }

  /// Resolves a persisted value to the file's path in the current container.
  ///
  /// Older builds stored an absolute path; if that path no longer exists, the
  /// file is looked up by name in the current support directory. Returns the
  /// stored value when no candidate exists, so a temporarily unavailable file
  /// does not erase the listener's choice.
  Future<String?> restore(String? stored) async {
    if (stored == null || stored.isEmpty) return null;
    final String name = _baseName(stored);
    if (!name.startsWith(_filePrefix)) return stored;
    try {
      final Directory directory = await _directory();
      final File candidate = File(
        '${directory.path}${Platform.pathSeparator}$name',
      );
      if (await candidate.exists()) return candidate.path;
    } catch (_) {
      // A missing/unreadable directory keeps the preference as it was.
    }
    return stored;
  }

  /// Removes a copy this app wrote. The name is resolved in the current
  /// container as well, so a stale absolute path cannot leave an orphan.
  Future<void> delete(String? stored) async {
    if (stored == null || stored.isEmpty) return;
    final String name = _baseName(stored);
    if (!name.startsWith(_filePrefix)) return;
    try {
      final Directory directory = await _directory();
      final File candidate = File(
        '${directory.path}${Platform.pathSeparator}$name',
      );
      if (await candidate.exists()) {
        await candidate.delete();
        return;
      }
      if (stored != name) {
        final File oldFile = File(stored);
        if (await oldFile.exists()) await oldFile.delete();
      }
    } catch (_) {
      // A leftover copy is harmless; never fail the settings action over it.
    }
  }
}

/// The store used by the running app.
final BackgroundImageStore backgroundImageStore = BackgroundImageStore();

/// Asks the platform picker for a picture and copies it into the app's support
/// directory. Returns the stored path, or null when the listener cancels.
///
/// Android and iOS open the photo library through `image_picker` (the system
/// photo picker on Android); desktop keeps the file dialog. The returned file
/// is always an app-owned copy: a picker's temporary file can be cleaned up
/// when the app is backgrounded.
Future<String?> pickCustomBackgroundImage({BackgroundImageStore? store}) async {
  final XFile? file = await _pickImageFile();
  if (file == null) return null;
  final Uint8List bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  return (store ?? backgroundImageStore).write(bytes, sourceName: file.name);
}

Future<XFile?> _pickImageFile() async {
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      return await ImagePicker().pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
    } on PlatformException {
      // Some large-screen Android devices ship no photo picker. Fall back to
      // the document picker instead of leaving the setting with no action.
    }
  }
  return openFile(acceptedTypeGroups: const <XTypeGroup>[_imageTypeGroup]);
}

/// Removes a stored backdrop copy. Only files this app wrote are touched, so a
/// stale preference can never delete a picture outside the support directory.
Future<void> deleteCustomBackgroundImage(String? path) =>
    backgroundImageStore.delete(path);

String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

String _extensionOf(String path) {
  final String name = _baseName(path);
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '.png';
  final String extension = name.substring(dot).toLowerCase();
  return extension.length <= 6 ? extension : '.png';
}
