// Guards the Dart mirror of `lazer_audio_api.h`.
//
// The layout expectations themselves live in `tool/native/abi_layout.dart` so the
// same checks can also run without a Flutter toolchain
// (`dart tool/native_abi_check.dart`), which is how they are verified on hosts
// that cannot build the engine.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';

import '../../tool/native/abi_layout.dart';

void main() {
  tearDownAll(disposeAbiLayoutProbes);

  test('every ABI struct matches the C compiler layout', () {
    expect(verifyAbiLayout(), isEmpty);
  });

  test('the ABI version matches the header this mirror was written for', () {
    expect(lazerAudioAbiVersion, 27);
  });

  test('open params carry the struct size the native side validates', () {
    final Pointer<LazerAudioOpenParams> params = calloc<LazerAudioOpenParams>();
    addTearDown(() => calloc.free(params));
    writeOpenParams(
      params,
      start: const Duration(seconds: 3),
      durationHint: const Duration(minutes: 4),
    );
    expect(params.ref.structSize, sizeOf<LazerAudioOpenParams>());
    expect(params.ref.startMillis, 3000);
    expect(params.ref.durationHintMillis, 240000);
    expect(params.ref.cueStartFrame75, 0);
    expect(params.ref.cueEndFrame75, 0);
    expect(params.ref.replayGainDb, 0);
  });

  test('the default device config is shared mode at the source rate', () {
    final Pointer<LazerAudioDeviceConfig> config =
        calloc<LazerAudioDeviceConfig>();
    addTearDown(() => calloc.free(config));
    writeDefaultDeviceConfig(config);
    expect(config.ref.deviceId, nullptr);
    expect(config.ref.exclusive, 0);
    expect(config.ref.resampleMode, lazerAudioResampleNative);
    expect(config.ref.bufferMillis, 120);
    expect(config.ref.bitPerfect, 0);
    expect(config.ref.dsdOutputMode, lazerAudioDsdOutputConvertToPcm);
  });

  test('the codec field is read as NUL-terminated ASCII', () {
    final Pointer<LazerAudioStreamInfo> info = calloc<LazerAudioStreamInfo>();
    addTearDown(() => calloc.free(info));
    const String codec = 'flac';
    for (int index = 0; index < codec.length; index++) {
      info.ref.codec[index] = codec.codeUnitAt(index);
    }
    expect(lazerCodecName(info.ref), 'flac');
  });
}
