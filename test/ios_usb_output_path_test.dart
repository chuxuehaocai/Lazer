import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';
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

  test('iOS product path hides dormant strict transport telemetry', () {
    // Format-selection values 13/14 remain in ABI 30 for historical and
    // diagnostic compatibility, but iOS never exposes that policy.
    native.ref
      ..outputFormatSelection = lazerAudioFormatSelectionIosUsbPcm
      ..outputFormatKind = lazerAudioOutputFormatPcm;
    final info = LazerStreamInfo.fromNative(native.ref);
    final rows = {
      for (final row in signalPathReadouts(info: info, iosSystemRoute: true))
        row.label: row.value,
    };
    expect(rows['严格输出'], '不支持');
    expect(rows, isNot(contains('Bit-perfect')));
    expect(rows, isNot(contains('独占')));
    expect(rows, isNot(contains('格式选择')));
    expect(rows, isNot(contains('格式与源一致')));
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
