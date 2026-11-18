import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';
import 'package:lazer_nextgen/audio/native/output_path_state.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section_io.dart';

void main() {
  late Pointer<LazerAudioStreamInfo> native;
  setUp(() {
    native = calloc<LazerAudioStreamInfo>();
    native.ref
      ..outputFormatInitialized = 1
      ..outputSampleRate = 176400
      ..outputBitsPerSample = 24
      ..outputChannels = 2
      ..outputContainerBitsPerSample = 24
      ..outputFormatMatchesSource = 1
      ..bitPerfectActive = 1;
  });
  tearDown(() => calloc.free(native));

  for (final (selection, kind, label) in [
    (
      lazerAudioFormatSelectionIosUsbPcm,
      lazerAudioOutputFormatPcm,
      'USB 严格 PCM（实验性）',
    ),
    (
      lazerAudioFormatSelectionIosUsbDoP,
      lazerAudioOutputFormatDoP,
      'USB DoP 载波（实验性）',
    ),
  ]) {
    test(
      '$label reports validated client transport without hardware exclusivity',
      () {
        native.ref
          ..outputFormatSelection = selection
          ..outputFormatKind = kind;
        final info = LazerStreamInfo.fromNative(native.ref);
        final path = info.outputPath;
        expect(info.isStrictIosUsbOutput, isTrue);
        expect(path.transparentUsb, isTrue);
        expect(path.exclusive, isFalse);
        expect(path.bitPerfect, isTrue);
        expect(path.agreesWithEngine, isTrue);
        expect(path.failingConditions, isEmpty);
        expect(path.bitPerfectMeaning, contains('未验证物理 DAC'));
        final direct = OutputPathState.fromNative(native.ref);
        expect(direct.transparentUsb, isTrue);
        expect(direct.bitPerfect, path.bitPerfect);
        final rows = {
          for (final row in signalPathReadouts(info: info))
            row.label: row.value,
        };
        expect(rows['独占'], '否');
        expect(rows['Bit-perfect'], 'USB 严格输出（未作硬件位校验）');
        expect(rows['格式选择'], label);
      },
    );
  }

  test('strict USB classification cannot conceal DSP or a format mismatch', () {
    native.ref.outputFormatSelection = lazerAudioFormatSelectionIosUsbPcm;
    native.ref.outputDspActive = 1;
    var path = LazerStreamInfo.fromNative(native.ref).outputPath;
    expect(path.bitPerfect, isFalse);
    expect(path.agreesWithEngine, isFalse);
    expect(path.failingConditions, contains('DSP 在信号路径中'));
    native.ref
      ..outputDspActive = 0
      ..outputFormatMatchesSource = 0;
    path = LazerStreamInfo.fromNative(native.ref).outputPath;
    expect(path.bitPerfect, isFalse);
    expect(path.failingConditions, contains('输出格式与源不一致'));
    native.ref
      ..outputFormatMatchesSource = 1
      ..outputFormatInitialized = 0;
    path = LazerStreamInfo.fromNative(native.ref).outputPath;
    expect(path.bitPerfect, isFalse);
    expect(path.failingConditions, contains('没有已初始化的输出会话'));
  });

  test('ordinary shared output does not inherit the USB strict claim', () {
    native.ref.outputFormatSelection = lazerAudioFormatSelectionSharedMix;
    final info = LazerStreamInfo.fromNative(native.ref);
    expect(info.isStrictIosUsbOutput, isFalse);
    expect(info.outputPath.bitPerfect, isFalse);
    expect(info.outputPath.agreesWithEngine, isFalse);
    expect(info.outputPath.failingConditions, contains('输出不是独占'));
  });

  test('desktop exact exclusive output keeps its existing verdict', () {
    native.ref
      ..outputFormatSelection = lazerAudioFormatSelectionExclusiveSource
      ..outputExclusive = 1;
    final info = LazerStreamInfo.fromNative(native.ref);
    expect(info.outputPath.transparentUsb, isFalse);
    expect(info.outputPath.bitPerfect, isTrue);
    final rows = {
      for (final row in signalPathReadouts(info: info)) row.label: row.value,
    };
    expect(rows['Bit-perfect'], '是（独占 · 无 DSP · 格式一致）');
    expect(rows['独占'], '是');
  });
}
