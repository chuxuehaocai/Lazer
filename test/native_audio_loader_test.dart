import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

/// The iOS engine is a static archive force-loaded into Runner and reached
/// through `DynamicLibrary.process()`. There is no file to inspect, so the only
/// thing that can tell a working link from a broken one is the symbol list this
/// loader requires — and the same list the build and package checks use.
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

  test('iOS is offered the native path without a loadable file', () {
    // The reason a host is supported is a backend, not a file name: iOS has the
    // RemoteIO backend and links the engine in, so an empty candidate list there
    // is not a downgrade.
    if (!Platform.isIOS) {
      expect(
        LazerAudioLoader.isSupportedHost,
        isTrue,
        reason: 'this development host ships a loadable engine',
      );
      return;
    }
    expect(LazerAudioLoader.isSupportedHost, isTrue);
    final LazerAudioAvailability availability = LazerAudioLoader.load();
    expect(availability.api, isNotNull, reason: availability.reason);
    expect(availability.reason, isNull);
  });
}
