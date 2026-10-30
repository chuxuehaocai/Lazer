import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_paths.dart';

void main() {
  late Directory root, checkout, bundle;
  setUp(() {
    root = Directory.systemTemp.createTempSync('lazer-paths-');
    checkout = Directory('${root.path}/checkout')..createSync();
    bundle = Directory('${root.path}/bundle')..createSync();
    for (final name in [
      'pubspec.yaml',
      'native/lazer-audio/include/lazer_audio_api.h',
    ]) {
      final file = File('${checkout.path}/$name');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('');
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  File library(Directory directory, [String name = 'lazer-audio.dll']) {
    directory.createSync(recursive: true);
    return File('${directory.path}/$name')..writeAsStringSync('fixture');
  }

  NativeAudioLibraryPaths paths({
    bool development = true,
    bool linux = false,
    bool android = false,
  }) => NativeAudioLibraryPaths(
    workingDirectory: checkout,
    executableDirectory: bundle,
    development: development,
    linux: linux,
    android: android,
  );
  Uri? resolve(NativeAudioLibraryPaths paths) =>
      paths.resolve(fileNames: ['lazer-audio.dll']);

  test('development prefers root engine over an older executable sibling', () {
    final local = library(checkout);
    library(bundle);
    expect(resolve(paths()), local.absolute.uri);
    expect(
      paths()
          .dependencyDirectories(local.absolute.uri)
          .map((d) => d.absolute.uri),
      [
        checkout.absolute.uri,
        Directory('${checkout.path}/build/native-audio').absolute.uri,
      ],
    );
  });
  test('release uses bundled engine and ignores checkout artifacts', () {
    library(checkout);
    library(Directory('${checkout.path}/build/native-audio'));
    final installed = library(bundle);
    expect(resolve(paths(development: false)), installed.absolute.uri);
    installed.deleteSync();
    expect(resolve(paths(development: false)), isNull);
  });
  test('installed debug build ignores unrelated working directory DLLs', () {
    library(checkout);
    File('${checkout.path}/pubspec.yaml').deleteSync();
    expect(resolve(paths()), isNull);
  });
  test('imports and environment overrides precede development engine', () {
    library(checkout);
    final imported = library(Directory('${root.path}/imported'));
    expect(
      paths().resolve(
        fileNames: ['lazer-audio.dll'],
        explicitPath: imported.path,
      ),
      imported.absolute.uri,
    );
    expect(
      paths().resolve(
        fileNames: ['lazer-audio.dll'],
        environmentOverride: imported.path,
      ),
      imported.absolute.uri,
    );
    expect(
      paths().resolve(
        fileNames: ['lazer-audio.dll'],
        explicitPath: '${root.path}/missing.dll',
      ),
      isNull,
    );
    expect(paths().dependencyDirectories(imported.absolute.uri), hasLength(1));
  });
  test('bridge beside selected engine precedes other bridges', () {
    final imported = library(
      Directory('${root.path}/imported'),
      'lazer-audio-bridge.dll',
    );
    library(checkout, 'lazer-audio-bridge.dll');
    expect(
      paths().resolve(
        fileNames: ['lazer-audio-bridge.dll'],
        siblingDirectory: imported.parent.path,
      ),
      imported.absolute.uri,
    );
  });
  test(
    'Linux bundles resolve lib child and Android delegates to native loader',
    () {
      final installed = library(
        Directory('${bundle.path}/lib'),
        'liblazer-audio.so',
      );
      expect(
        paths(
          development: false,
          linux: true,
        ).resolve(fileNames: ['liblazer-audio.so']),
        installed.absolute.uri,
      );
      expect(
        paths(android: true).resolve(fileNames: ['liblazer-audio.so']),
        Uri.file('liblazer-audio.so'),
      );
    },
  );
}
