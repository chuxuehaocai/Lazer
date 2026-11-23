// Chooses which playback engine this launch runs on.
//
// The master branch's native engine (FFmpeg decode + WASAPI/ALSA/CoreAudio
// output, DSD, gapless) is preferred on desktop. It is only used when its shared
// library is present next to the app and reports the ABI version this build
// expects; otherwise the app keeps `just_audio`/media_kit, so a plain
// `flutter run` from a checkout without a built engine behaves exactly as before.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'audio_engine.dart';
import 'automix_audio_engine.dart';
import 'native/audio_path_log.dart';
import 'native/engine_selection.dart';
import 'native/lazer_audio_engine.dart';
import 'native/lazer_audio_library.dart';
import 'native/lazer_audio_worker.dart';

/// Whether [engine] is the native FFI session. Kept behind the platform
/// factory so shared state never imports `dart:ffi` on the web.
bool isNativeAudioEngine(AudioEngine engine) => engine is NativeAudioEngine;

/// Deadline for one native session start-up.
///
/// The native engine reserves an output device for the lifetime of the process,
/// and a hot restart never runs the previous isolate's teardown, so that
/// reservation outlives the Dart code that made it. A second
/// `lazer_audio_create` can therefore wait on a device nothing will release; the
/// deadline turns that into a visible fallback instead of a window that never
/// appears. The abandoned future may still finish and reserve the device — it
/// cannot be cancelled from here — but an unreachable engine costs less than a
/// start-up that never completes.
const Duration _nativeStartupDeadline = Duration(seconds: 8);

/// The engine plus, when present, the native session and its diagnostics.
@immutable
class AudioEngineSelection {
  const AudioEngineSelection({
    required this.engine,
    required this.path,
    this.native,
    this.platform,
  });

  /// The engine the app drives; one of [native] or [platform].
  final AudioEngine engine;

  /// Which path this launch runs on, and why it is not the native one.
  ///
  /// The player shows [AudioEnginePathDecision.notice], so a fallback is never
  /// silent; [AudioEnginePathDecision.detail] carries the loader's reason or the
  /// startup error verbatim.
  final AudioEnginePathDecision path;

  /// Non-null when the native HiFi engine is driving playback.
  final NativeAudioEngine? native;

  /// Non-null when `just_audio`/media_kit is driving playback.
  final AudioEngine? platform;

  bool get isNative => native != null;

  /// `native (lazer-audio)` or `just_audio (reason)`.
  String get description => path.description;
}

/// Creates the playback engine for this launch.
///
/// Returns the native engine when [preferNative] and this host has a usable
/// binary; the platform engine otherwise. Never throws: a failed native start-up
/// is logged and falls back, because a missing engine must not stop the app from
/// playing music. The returned [AudioEngineSelection.path] always says which
/// path won and why — a downgrade that reached only the log would be
/// indistinguishable from a native session for the listener.
Future<AudioEngineSelection> createAudioEngine({
  bool preferNative = true,
  bool autoMixEnabled = false,
  LazerDeviceSettings deviceSettings = const LazerDeviceSettings(),
}) async {
  AudioEnginePathDecision decision = planAudioEnginePath(
    preferNative: preferNative,
    hostSupported: LazerAudioLoader.isSupportedHost,
    libraryUnavailableReason: preferNative && LazerAudioLoader.isSupportedHost
        ? LazerAudioLoader.load().reason
        : null,
  );
  if (decision.isNative) {
    try {
      final NativeAudioEngine? native = await NativeAudioEngine.create(
        deviceSettings: deviceSettings,
      ).timeout(_nativeStartupDeadline);
      if (native != null) {
        if (native.supportsAutoMix) {
          await native.setAutoMixEnabled(autoMixEnabled);
        }
        logAudioPathEvent('select', <String, Object?>{
          'path': 'native',
          'fallback': null,
          'detail': null,
        });
        logAudioPathEvent('session', <String, Object?>{
          'engine': 'lazer-audio',
          // The build line carries the FFmpeg component versions, which is what
          // tells two otherwise identical bundles apart in a bug report.
          'build': native.buildInformation.split('\n').first,
        });
        return AudioEngineSelection(
          engine: native,
          native: native,
          path: decision,
        );
      }
      // The library loaded, so the reason is *not* the loader's: the session
      // itself refused to start (no usable device, endpoint held elsewhere).
      decision = AudioEnginePathDecision.fallback(
        AudioPathFallback.sessionStartupFailed,
        NativeAudioEngine.lastStartupFailure ??
            'lazer_audio_create returned no engine',
      );
    } on TimeoutException {
      // Say what the listener can act on: a device held by a dead instance is
      // only released by restarting the app, and playback is already working on
      // the fallback path by the time this notice is read.
      decision = AudioEnginePathDecision.fallback(
        AudioPathFallback.sessionStartupFailed,
        'native start-up did not finish in ${_nativeStartupDeadline.inSeconds}s '
        '(an output device may still be held by the previous run); '
        '${NativeAudioEngine.lastStartupFailure ?? "no engine reported"}',
      );
      debugPrint('Audio engine: native start-up timed out, falling back');
    } catch (error, stack) {
      decision = AudioEnginePathDecision.fallback(
        AudioPathFallback.sessionStartupFailed,
        '$error',
      );
      debugPrint(
        'Audio engine: native start-up threw, falling back: $error\n$stack',
      );
    }
    logAudioPathEvent('fallback', <String, Object?>{
      'path': 'just_audio',
      'fallback': decision.fallback!.name,
      'detail': decision.detail,
    });
  } else {
    logAudioPathEvent('select', <String, Object?>{
      'path': 'just_audio',
      'fallback': decision.fallback!.name,
      'detail': decision.detail,
    });
  }
  debugPrint(
    'Audio engine: falling back to just_audio (${decision.detail ?? decision.fallback!.name})',
  );
  JustAudioMediaKit.ensureInitialized();
  JustAudioMediaKit.prefetchPlaylist = true;
  // Keep both decoders available so the setting also works when enabled during
  // playback; this remains the system backend, independent of engine choice.
  final AudioEngine platform = AutoMixAudioEngine(
    enabled: autoMixEnabled,
    fallbackNotice: decision.notice,
  );
  return AudioEngineSelection(
    engine: platform,
    platform: platform,
    path: decision,
  );
}
