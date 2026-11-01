import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/build_native_audio.dart';

void main() {
  late Directory root, staging;
  setUp(() {
    root = Directory.systemTemp.createTempSync('native-audio-staging-');
    staging = Directory('${root.path}/staging')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  File fixture(String name, String content) =>
      File('${root.path}/$name')..writeAsStringSync(content);

  test('requires each FFmpeg runtime before publishing a bundle', () {
    expect(
      missingNativeFfmpegComponents([
        'avcodec-63.dll',
        'avformat-63.dll',
        'avutil-61.dll',
      ]),
      ['swresample'],
    );
    expect(missingNativeFfmpegComponents([]), hasLength(4));
    for (final names in [
      [
        'AVCODEC-63.dll',
        'avformat-63.dll',
        'avutil-61.dll',
        'swresample-7.dll',
      ],
      [
        'libavcodec.so.63',
        'libavformat.so',
        'libavutil.so',
        'libswresample.so',
      ],
      [
        'libavcodec.dylib',
        'libavformat.dylib',
        'libavutil.dylib',
        'libswresample.dylib',
      ],
    ]) {
      expect(missingNativeFfmpegComponents(names), isEmpty);
    }
  });

  test('publishes the complete engine and reader runtime', () async {
    final engine = fixture('engine-new', 'ABI 27');
    final bridge = fixture('bridge-new', 'reader');
    final engineTarget = fixture('engine', 'ABI 24');
    final bridgeTarget = File('${root.path}/bridge');
    await publishNativeAudioFiles([
      (source: engine, target: engineTarget),
      (source: bridge, target: bridgeTarget),
    ], staging);
    expect(engineTarget.readAsStringSync(), 'ABI 27');
    expect(bridgeTarget.readAsStringSync(), 'reader');
  });

  test('unchanged libraries are left in place', () async {
    final source = fixture('source', 'reader');
    final target = fixture('target', 'reader');
    final before = DateTime(2000);
    target.setLastModifiedSync(before);
    await publishNativeAudioFiles([(source: source, target: target)], staging);
    expect(target.lastModifiedSync(), before);
    expect(staging.listSync(), isEmpty);
  });

  test('a failed companion update restores the previous engine', () async {
    final engine = fixture('engine-new', 'ABI 27');
    final bridge = fixture('bridge-new', 'reader');
    final target = fixture('engine', 'ABI 24');
    final blocked = Directory('${root.path}/blocked')..createSync();
    await expectLater(
      publishNativeAudioFiles([
        (source: engine, target: target),
        (source: bridge, target: File(blocked.path)),
      ], staging),
      throwsA(isA<FileSystemException>()),
    );
    expect(target.readAsStringSync(), 'ABI 24');
    expect(blocked.existsSync(), isTrue);
  });

  test('a failed update removes newly published files', () async {
    final source = fixture('source', 'reader');
    final target = File('${root.path}/new-engine');
    final blocked = Directory('${root.path}/blocked')..createSync();
    await expectLater(
      publishNativeAudioFiles([
        (source: source, target: target),
        (source: source, target: File(blocked.path)),
      ], staging),
      throwsA(isA<FileSystemException>()),
    );
    expect(target.existsSync(), isFalse);
  });
}
