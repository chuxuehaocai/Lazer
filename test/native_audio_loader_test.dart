import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

/// The native engine is loaded from a platform library on supported desktop
/// and Android hosts. iOS uses the platform audio plugin instead.
void main() {
  test('the required ABI list matches the C header contract', () {
    final String header = File(
      'native/lazer-audio/include/lazer_audio_api.h',
    ).readAsStringSync();
    for (final String symbol in requiredEngineSymbols) {
      expect(
        header,
        contains(symbol),
        reason:
            '$symbol is required by the loader but is not in the ABI header',
      );
    }
    // The header and Dart mirror must move together; the loader
    // refuses any other number rather than reading a misaligned struct.
    final RegExpMatch? versionMatch = RegExp(
      r'^#define LAZER_AUDIO_ABI_VERSION ([0-9]+)u$',
      multiLine: true,
    ).firstMatch(header);
    expect(versionMatch, isNotNull);
    expect(int.parse(versionMatch!.group(1)!), lazerAudioAbiVersion);
    expect(lazerAudioAbiVersion, 31);
  });

  test('the required ABI list does not gate additive entry points', () {
    // These are looked up optionally: an engine without them still plays, and
    // requiring them would make an older-but-usable engine report unavailable.
    for (final String additive in const <String>[
      'lazer_audio_set_automix',
      'lazer_audio_read_log',
      'lazer_audio_output_device_catalog_create',
      'lazer_audio_device_catalog_create',
    ]) {
      expect(
        requiredEngineSymbols,
        isNot(contains(additive)),
        reason: '$additive is additive and must stay optional',
      );
    }
  });

  test('iOS uses the platform audio path', () {
    if (!Platform.isIOS) {
      expect(
        LazerAudioLoader.isSupportedHost,
        isTrue,
        reason: 'this development host ships a loadable engine',
      );
      return;
    }
    expect(LazerAudioLoader.isSupportedHost, isFalse);
  });
}
