// Chooses which playback engine this launch runs on.
//
// The master branch's native engine (FFmpeg decode + WASAPI/ALSA/CoreAudio
// output, DSD, gapless) is preferred on desktop. It is only used when its shared
// library is present next to the app and reports the ABI version this build
// expects; otherwise the app keeps `just_audio`/media_kit, so a plain
// `flutter run` from a checkout without a built engine behaves exactly as before.
library;

import 'package:flutter/foundation.dart';

import 'audio_engine.dart';
import 'native/lazer_audio_engine.dart';
import 'native/lazer_audio_library.dart';
import 'native/lazer_audio_worker.dart';

/// The engine plus, when present, the native session and its diagnostics.
@immutable
class AudioEngineSelection {
  const AudioEngineSelection({required this.engine, this.native, this.platform});

  /// The engine the app drives; one of [native] or [platform].
  final AudioEngine engine;

  /// Non-null when the native HiFi engine is driving playback.
  final NativeAudioEngine? native;

  /// Non-null when `just_audio`/media_kit is driving playback.
  final JustAudioEngine? platform;

  bool get isNative => native != null;

  /// Why the native engine was not used, for logs and the diagnostics panel.
  String get description => native != null
      ? 'native (lazer-audio)'
      : 'just_audio${_nativeUnavailableReason == null ? '' : ' (${_nativeUnavailableReason!})'}';

  static String? _nativeUnavailableReason;
}

/// Creates the playback engine for this launch.
///
/// Returns the native engine when [preferNative] and this host has a usable
/// binary; the platform engine otherwise. Never throws: a failed native start-up
/// is logged and falls back, because a missing engine must not stop the app from
/// playing music.
Future<AudioEngineSelection> createAudioEngine({
  bool preferNative = true,
  LazerDeviceSettings deviceSettings = const LazerDeviceSettings(),
}) async {
  if (preferNative && LazerAudioLoader.isSupportedHost) {
    try {
      final NativeAudioEngine? native = await NativeAudioEngine.create(
        deviceSettings: deviceSettings,
      );
      if (native != null) {
        debugPrint('Audio engine: ${native.buildInformation.split('\n').first}');
        return AudioEngineSelection(engine: native, native: native);
      }
    } catch (error, stack) {
      debugPrint('Audio engine: native start-up threw, falling back: $error\n$stack');
    }
    AudioEngineSelection._nativeUnavailableReason =
        LazerAudioLoader.load().reason;
    debugPrint(
      'Audio engine: falling back to just_audio '
      '(${AudioEngineSelection._nativeUnavailableReason})',
    );
  }
  final JustAudioEngine platform = JustAudioEngine();
  return AudioEngineSelection(engine: platform, platform: platform);
}
