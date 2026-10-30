import 'dart:io';

/// Keeps repository artifacts out of installed/release library searches.
class NativeAudioLibraryPaths {
  NativeAudioLibraryPaths({
    required this.workingDirectory,
    required this.executableDirectory,
    required bool development,
    this.linux = false,
    this.android = false,
  }) : developmentCheckout =
           development &&
           !android &&
           File('${workingDirectory.path}/pubspec.yaml').existsSync() &&
           File(
             '${workingDirectory.path}/native/lazer-audio/include/lazer_audio_api.h',
           ).existsSync();

  final Directory workingDirectory, executableDirectory;
  final bool developmentCheckout, linux, android;

  Iterable<Directory> get directories sync* {
    if (developmentCheckout) {
      yield workingDirectory;
      yield Directory('${workingDirectory.path}/build/native-audio');
    }
    yield executableDirectory;
    if (linux) yield Directory('${executableDirectory.path}/lib');
    if (!developmentCheckout) return;
    for (final root in ['build/native-audio', 'build/native']) {
      for (final target in ['', 'lazer-audio', 'lazer-audio-bridge']) {
        for (final configuration in ['', 'Debug', 'Profile', 'Release']) {
          yield Directory(
            [
              workingDirectory.path,
              root,
              if (target.isNotEmpty) target,
              if (configuration.isNotEmpty) configuration,
            ].join(Platform.pathSeparator),
          );
        }
      }
    }
  }

  Uri? resolve({
    required List<String> fileNames,
    String? explicitPath,
    String? environmentOverride,
    String? siblingDirectory,
  }) {
    if (explicitPath != null) {
      final file = File(explicitPath);
      return file.existsSync() ? file.absolute.uri : null;
    }
    if (siblingDirectory != null) {
      final found = _inDirectory(Directory(siblingDirectory), fileNames);
      if (found != null) return found;
    }
    if (environmentOverride != null && environmentOverride.trim().isNotEmpty) {
      final file = File(environmentOverride.trim());
      if (file.existsSync()) return file.absolute.uri;
    }
    if (android) return Uri.file(fileNames.first);
    for (final directory in directories) {
      final found = _inDirectory(directory, fileNames);
      if (found != null) return found;
    }
    return null;
  }

  Iterable<Directory> dependencyDirectories(Uri enginePath) sync* {
    final adjacent = File.fromUri(enginePath).parent;
    yield adjacent;
    if (developmentCheckout &&
        adjacent.absolute.uri == workingDirectory.absolute.uri) {
      yield Directory('${workingDirectory.path}/build/native-audio');
    }
  }

  Uri? _inDirectory(Directory directory, List<String> names) {
    for (final name in names) {
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      if (file.existsSync()) return file.absolute.uri;
    }
    return null;
  }
}
