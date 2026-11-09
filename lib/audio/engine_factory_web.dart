import 'package:flutter/foundation.dart';

import 'audio_engine.dart';
import 'automix_audio_engine.dart';
import 'native/engine_selection.dart';

/// The browser has no native FFI session.
bool isNativeAudioEngine(AudioEngine engine) => false;

/// The engine plus, when present, the native session and its diagnostics.
@immutable
class AudioEngineSelection {
  const AudioEngineSelection({
    required this.engine,
    required this.path,
    this.native,
    this.platform,
  });

  final AudioEngine engine;
  final AudioEnginePathDecision path;

  /// Always null on the web; kept so the shared entry point compiles.
  final Object? native;

  /// Non-null when `just_audio` is driving playback.
  final AudioEngine? platform;

  bool get isNative => false;

  String get description => path.description;
}

/// The browser has no native HiFi backend, so playback always runs on
/// `just_audio`'s HTML audio implementation.
Future<AudioEngineSelection> createAudioEngine({
  bool preferNative = true,
  bool autoMixEnabled = false,
}) async {
  final AudioEngine platform = AutoMixAudioEngine(
    enabled: autoMixEnabled,
    fallbackNotice: null,
  );
  return AudioEngineSelection(
    engine: platform,
    platform: platform,
    path: const AudioEnginePathDecision.fallback(
      AudioPathFallback.unsupportedHost,
    ),
  );
}
