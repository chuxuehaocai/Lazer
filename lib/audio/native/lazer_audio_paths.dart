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
  /// build cannot hide a compatible engine later in the search.
  ///
  /// An explicit choice — a library the user imported, or a per-process
  /// `LAZER_AUDIO_LIBRARY` override — is tried first, but it is not the only
  /// candidate. It used to short-circuit discovery, which made a stale import
  /// from an older build fatal: once the ABI moved on, or the copied file was
  /// deleted, the engine reported itself unavailable even though the app ships
  /// a working one, and the app silently fell back to the system engine until
  /// the user found the "use the bundled engine" row and restarted. Loading an
  /// explicit path that turns out to be unusable now just means the next
  /// candidate runs; the loader keeps the failure in its reason so the settings
  /// page can still say why the import was ignored.
  Iterable<Uri> candidates({
    required List<String> fileNames,
    String? explicitPath,
    String? environmentOverride,
    String? siblingDirectory,
  }) sync* {
    final seen = <Uri>{};
    for (final path in <String?>[explicitPath, environmentOverride?.trim()]) {
      if (path == null || path.isEmpty) continue;
      final file = File(path);
      final uri = file.absolute.uri;
      if (file.existsSync() && seen.add(uri)) yield uri;
    }
    if (android) {
      yield Uri.file(fileNames.first);
      return;
    }
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
