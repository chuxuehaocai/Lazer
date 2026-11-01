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
      yield Directory('${workingDirectory.path}/build/native-audio');
      yield workingDirectory;
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
  }) => candidates(
    fileNames: fileNames,
    explicitPath: explicitPath,
    environmentOverride: environmentOverride,
    siblingDirectory: siblingDirectory,
  ).firstOrNull;

  /// Automatic discovery tries every existing artifact, so an obsolete local
  /// build cannot hide a compatible engine later in the search. Explicit user
  /// choices are authoritative, including missing or incompatible files.
  Iterable<Uri> candidates({
    required List<String> fileNames,
    String? explicitPath,
    String? environmentOverride,
    String? siblingDirectory,
  }) sync* {
    if (explicitPath != null) {
      final file = File(explicitPath);
      if (file.existsSync()) yield file.absolute.uri;
      return;
    }
    if (environmentOverride != null && environmentOverride.trim().isNotEmpty) {
      final file = File(environmentOverride.trim());
      if (file.existsSync()) yield file.absolute.uri;
      return;
    }
    if (android) {
      yield Uri.file(fileNames.first);
      return;
    }
    final seen = <Uri>{};
    for (final directory in [
      if (siblingDirectory != null) Directory(siblingDirectory),
      ...directories,
    ]) {
      for (final name in fileNames) {
        final file = File('${directory.path}${Platform.pathSeparator}$name');
        final uri = file.absolute.uri;
        if (seen.add(uri) && file.existsSync()) yield uri;
      }
    }
  }

  Iterable<Directory> dependencyDirectories(Uri enginePath) sync* {
    final adjacent = File.fromUri(enginePath).parent;
    yield adjacent;
    if (developmentCheckout &&
        adjacent.absolute.uri == workingDirectory.absolute.uri) {
      yield Directory('${workingDirectory.path}/build/native-audio');
    }
  }
}
