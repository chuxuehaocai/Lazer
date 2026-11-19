import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_paths.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

/// A user import or a `LAZER_AUDIO_LIBRARY` override is a *preference*, not the
/// only candidate: a library copied out of an older build keeps its path in the
/// preferences after the ABI moves on, and short-circuiting discovery on it left
/// the engine unavailable — and the app on the system engine — even though the
/// bundle shipped a matching one. These cases pin the ordering and that
/// property: preferred paths first, discovery always still reachable.
void main() {
  late Directory root;
  late Directory executable;
  late Directory bundle;

  NativeAudioLibraryPaths paths({bool android = false}) =>
      NativeAudioLibraryPaths(
        workingDirectory: root,
        executableDirectory: executable,
        development: false,
        android: android,
      );

  String at(Directory directory, String name) =>
      '${directory.path}${Platform.pathSeparator}$name';

  /// Candidates come back as file URIs, so the expectation has to be spelled
  /// the same way: `File.absolute` keeps whatever separators the caller used.
  String normalised(String path) => File(path).absolute.uri.toFilePath();

  List<String> names(Iterable<Uri> candidates) => [
    for (final Uri uri in candidates) uri.toFilePath(),
  ];

  setUp(() {
    root = Directory.systemTemp.createTempSync('lazer-paths-');
    executable = Directory(at(root, 'app'))..createSync();
    bundle = Directory(at(root, 'bundle'))..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('an explicit path is tried first and discovery still follows', () {
    final File bundled = File(at(executable, 'lazer-audio.dll'))
      ..writeAsStringSync('bundled');
    final File imported = File(at(bundle, 'lazer-audio.dll'))
      ..writeAsStringSync('imported');

    final List<String> found = names(
      paths().candidates(
        fileNames: const <String>['lazer-audio.dll'],
        explicitPath: imported.path,
      ),
    );

    expect(found.first, normalised(imported.path));
    expect(
      found,
      contains(normalised(bundled.path)),
      reason: 'a failing import must not hide the engine shipped with the app',
    );
  });

  test('a missing explicit path leaves every discovery candidate', () {
    final File bundled = File(at(executable, 'lazer-audio.dll'))
      ..writeAsStringSync('bundled');

    final List<String> found = names(
      paths().candidates(
        fileNames: const <String>['lazer-audio.dll'],
        explicitPath: at(bundle, 'deleted-by-an-upgrade/lazer-audio.dll'),
      ),
    );

    expect(found, <String>[normalised(bundled.path)]);
  });

  test('the environment override is a preference too, and is deduplicated', () {
    final File bundled = File(at(executable, 'lazer-audio.dll'))
      ..writeAsStringSync('bundled');

    final List<String> found = names(
      paths().candidates(
        fileNames: const <String>['lazer-audio.dll'],
        explicitPath: bundled.path,
        // The same file with padding: one candidate, first, not twice.
        environmentOverride: '  ${bundled.path}  ',
      ),
    );

    expect(found, <String>[normalised(bundled.path)]);
  });

  test('a broken override does not remove the bundled engine', () {
    final File bundled = File(at(executable, 'lazer-audio.dll'))
      ..writeAsStringSync('bundled');

    final List<String> found = names(
      paths().candidates(
        fileNames: const <String>['lazer-audio.dll'],
        environmentOverride: at(bundle, 'not-built-yet/lazer-audio.dll'),
      ),
    );

    expect(found, <String>[normalised(bundled.path)]);
  });

  test('Android keeps the packaged library name as its candidate', () {
    final List<String> found = names(
      paths(
        android: true,
      ).candidates(fileNames: const <String>['liblazer-audio.so']),
    );

    expect(found, <String>['liblazer-audio.so']);
  });

  test('a stale ABI import falls through and keeps its failure reason', () {
    final Uri imported = Uri.file(
      '${root.path}${Platform.pathSeparator}old-import${Platform.pathSeparator}lazer-audio.dll',
    );
    final Uri bundled = Uri.file(at(executable, 'lazer-audio.dll'));
    final LazerAudioApi bundledApi = LazerAudioApi(DynamicLibrary.process());
    final List<String> probed = <String>[];

    final LazerAudioAvailability result = LazerAudioLoader.selectFirstUsable(
      <Uri>[imported, bundled],
      (Uri candidate) {
        probed.add(candidate.toFilePath());
        if (candidate == imported) {
          return const LazerAudioAvailability.unavailable(
            'old/lazer-audio.dll reports ABI 29; this build expects 30',
          );
        }
        return LazerAudioAvailability.available(
          bundledApi,
          null,
          source: LazerAudioEngineSource.bundled,
          sourceLabel: 'lazer-audio.dll',
        );
      },
      unavailableReason: 'no candidates',
    );

    expect(probed, <String>[imported.toFilePath(), bundled.toFilePath()]);
    expect(result.isAvailable, isTrue);
    expect(result.api, same(bundledApi));
    expect(result.reason, isNull);
    expect(
      result.rejectedCandidates,
      hasLength(1),
      reason: 'the ignored import must remain visible in diagnostics',
    );
    expect(result.rejectedCandidates.single, contains('ABI 29'));
  });

  test('empty persisted output fields mean the system default', () {
    final HifiSettings settings = HifiSettings.fromMap(<String, Object?>{
      'hifi_output_token': '',
      'hifi_output_name': '',
    });

    expect(settings.outputToken, isNull);
    expect(settings.outputName, isNull);
    expect(settings.hasOutputSelection, isFalse);
    expect(settings.toOutputRequest().token, isNull);
  });
}
