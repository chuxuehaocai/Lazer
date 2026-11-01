// Runs on an iOS runtime (simulator or device) and answers the one question the
// build and link checks cannot: when the app is actually running on iOS, does
// the loader reach the linked engine and does the engine answer?
//
// `ci/verify-ios-audio.py` proves the ABI symbols are in the executable's
// dynamic export trie; this proves `DynamicLibrary.process()` resolves them,
// the reported ABI matches the Dart mirror, the reader bridge came along, and
// the engine answers a call. Whether it then produces correct sound on a real
// route is still a device question (docs/audio-engine-hardware-verification.md
// section 11).
//
//   flutter test integration_test/ios_native_engine_test.dart -d <simulator>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS selects the linked native engine', (WidgetTester tester) async {
    expect(Platform.isIOS, isTrue, reason: 'this check only means something on iOS');
    expect(
      LazerAudioLoader.isSupportedHost,
      isTrue,
      reason: 'iOS must be offered the native path',
    );

    final LazerAudioAvailability availability = LazerAudioLoader.load(reload: true);
    // The reason text is what the player shows on a downgrade, so a failure
    // here has to name the missing piece.
    expect(availability.reason, isNull);
    expect(availability.api, isNotNull);

    final LazerAudioApi api = availability.api!;
    expect(api.abiVersion(), lazerAudioAbiVersion);

    // Every ABI symbol resolved out of the process image, so the engine is
    // callable, not merely present in the binary.
    expect(api.buildInformation(), isNotEmpty);

    // The reader bridge is what plays network sources; it is linked into the
    // same image, so streaming must survive on iOS.
    expect(
      availability.supportsStreaming,
      isTrue,
      reason: 'the reader bridge must be reachable in-process too',
    );
  });
}
