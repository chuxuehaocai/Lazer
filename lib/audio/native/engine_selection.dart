// Which playback path this launch runs on, and why.
//
// `engine_factory.dart` needs Flutter (`debugPrint`) and `just_audio`, so the
// decision itself lives here, free of Flutter imports: `tool/native_path_check.dart`
// and `flutter test` can then assert the decision — and the reason a launch is
// *not* on the native HiFi engine — without a running app.
//
// The reason is the whole point. A downgrade that only reaches the log is
// indistinguishable from a native session for the person listening, so every
// fallback carries a `fallback` kind plus the underlying detail text, and the
// player shows it (see `AudioPathBadge`).
library;

/// Which playback path a launch runs on.
enum AudioEnginePath {
  /// The native HiFi engine (FFmpeg decode + WASAPI/ALSA/CoreAudio output).
  native,

  /// `just_audio`/media_kit: the explicit, always-reported fallback.
  system,
}

/// Why a launch is not on the native path.
enum AudioPathFallback {
  /// The user picked 系统音频引擎 in the settings.
  userSelectedSystemEngine,

  /// This host has no native backend at all (iOS, 32-bit ARM Android, ...).
  unsupportedHost,

  /// The shared library is missing, fails to load, or reports another ABI.
  libraryUnavailable,

  /// The library loaded, but the engine session could not be created — no
  /// usable output device, an endpoint held exclusively by another player, or a
  /// failure inside `lazer_audio_create`.
  sessionStartupFailed,
}

/// The playback path of this launch plus the reason it is not the native one.
class AudioEnginePathDecision {
  const AudioEnginePathDecision._(this.path, this.fallback, this.detail);

  /// The native engine drives playback.
  const AudioEnginePathDecision.native()
    : this._(AudioEnginePath.native, null, null);

  /// The system engine drives playback, for [fallback] and [detail].
  const AudioEnginePathDecision.fallback(AudioPathFallback fallback, [String? detail])
    : this._(AudioEnginePath.system, fallback, detail);

  final AudioEnginePath path;

  /// Null exactly when [path] is [AudioEnginePath.native].
  final AudioPathFallback? fallback;

  /// The underlying reason text (the loader's reason, or the startup error).
  final String? detail;

  bool get isNative => path == AudioEnginePath.native;

  /// One line for logs and the diagnostics export: `native (lazer-audio)` or
  /// `just_audio (reason)`.
  String get description => isNative
      ? 'native (lazer-audio)'
      : 'just_audio${detail == null ? '' : ' ($detail)'}';

  /// The user-facing notice shown while this launch is not on the HiFi path,
  /// or null when it is.
  String? get notice => switch (fallback) {
    null => null,
    AudioPathFallback.userSelectedSystemEngine => '已选择系统音频引擎，当前非 HiFi 路径',
    AudioPathFallback.unsupportedHost => '当前平台没有原生 HiFi 引擎$_detailSuffix',
    AudioPathFallback.libraryUnavailable => '原生 HiFi 引擎不可用$_detailSuffix',
    AudioPathFallback.sessionStartupFailed => '原生 HiFi 引擎初始化失败$_detailSuffix',
  };

  /// `：reason`, or nothing when there is no detail.
  String get _detailSuffix {
    final String? text = detail;
    if (text == null || text.isEmpty) return '';
    // Callers pass loader/engine text through verbatim; a trailing period would
    // read as the end of the sentence rather than as a parenthetical.
    return '：${text.trim().replaceAll(RegExp(r'[.\s]+$'), '')}';
  }

  @override
  String toString() => 'AudioEnginePathDecision($description)';
}

/// Decides the path from the three facts the factory can observe before it
/// builds anything.
///
/// [libraryUnavailableReason] is `LazerAudioAvailability.reason`: null when the
/// engine library is loaded and reports this build's ABI.
AudioEnginePathDecision planAudioEnginePath({
  required bool preferNative,
  required bool hostSupported,
  String? libraryUnavailableReason,
}) {
  if (!preferNative) {
    return const AudioEnginePathDecision.fallback(
      AudioPathFallback.userSelectedSystemEngine,
    );
  }
  if (!hostSupported) {
    return AudioEnginePathDecision.fallback(
      AudioPathFallback.unsupportedHost,
      libraryUnavailableReason,
    );
  }
  if (libraryUnavailableReason != null) {
    return AudioEnginePathDecision.fallback(
      AudioPathFallback.libraryUnavailable,
      libraryUnavailableReason,
    );
  }
  return const AudioEnginePathDecision.native();
}

/// One structured `audio.path` record.
///
/// Kept a pure function so the app log and the `tool/` checks print the same
/// line: `audio.path event=format source=44100/16/2 ...`. Fields are emitted in
/// insertion order, `-` stands for an absent value, and values containing spaces
/// are quoted, so the records stay greppable in a CI log.
String formatAudioPathRecord(String event, [Map<String, Object?> fields = const {}]) {
  final StringBuffer buffer = StringBuffer('audio.path event=$event');
  for (final MapEntry<String, Object?> field in fields.entries) {
    final Object? value = field.value;
    final String text = value == null || '$value'.isEmpty ? '-' : '$value';
    buffer.write(' ${field.key}=${text.contains(' ') ? '"$text"' : text}');
  }
  return buffer.toString();
}
