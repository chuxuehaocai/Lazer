// Loading and binding of the native `lazer-audio` engine and its reader bridge.
//
// The engine is a single C ABI shared library (`lazer_audio_api.h`, ABI v30);
// the bridge is a tiny companion that implements the engine's reader callbacks
// over a growing cache file, because Dart cannot service a blocking native
// callback from an engine thread (see `lazer_audio_reader.dart`).
//
// Nothing here touches audio state: it resolves paths, opens the libraries,
// checks the ABI version, and exposes typed function pointers.
library;

import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';

import 'lazer_audio_abi.dart';
import 'lazer_audio_paths.dart';

/// Where the engine image actually came from for this launch.
enum LazerAudioEngineSource {
  /// A library the user chose in settings and that survived validation.
  imported('imported'),

  /// The explicit `LAZER_AUDIO_LIBRARY` process override.
  environment('environment'),

  /// The image shipped with the app or staged by the development build.
  bundled('bundled');

  const LazerAudioEngineSource(this.label);

  /// A stable, non-localized identifier for logs and diagnostics.
  final String label;
}

/// Result of trying to load the engine.
///
/// [api] is non-null only when both the library and the ABI version matched, so
/// callers can branch on `api != null` instead of catching.
///
/// Deliberately free of Flutter imports: the loader is exercised by plain-Dart
/// checks (`tool/`), where the Flutter SDK is not available.
class LazerAudioAvailability {
  const LazerAudioAvailability._({
    this.api,
    this.bridge,
    this.reason,
    this.source,
    this.sourceLabel,
    this.rejectedCandidates = const <String>[],
  });

  const LazerAudioAvailability.unavailable(
    String reason, {
    List<String> rejectedCandidates = const <String>[],
  }) : this._(reason: reason, rejectedCandidates: rejectedCandidates);

  const LazerAudioAvailability.available(
    LazerAudioApi api,
    LazerAudioBridgeApi? bridge, {
    required LazerAudioEngineSource source,
    required String sourceLabel,
    List<String> rejectedCandidates = const <String>[],
  }) : this._(
         api: api,
         bridge: bridge,
         source: source,
         sourceLabel: sourceLabel,
         rejectedCandidates: rejectedCandidates,
       );

  final LazerAudioApi? api;
  final LazerAudioBridgeApi? bridge;

  /// Why the engine cannot be used; null when it can.
  final String? reason;

  /// The actual image that was loaded, not merely the user's preference.
  final LazerAudioEngineSource? source;

  /// The selected image's basename, safe to show in settings and diagnostics.
  final String? sourceLabel;

  /// Candidate-specific failures that were skipped before [api] loaded.
  ///
  /// A stale user import is the common case: the app correctly continues to a
  /// bundled engine, but the settings page still needs to explain why the
  /// imported file was ignored.
  final List<String> rejectedCandidates;

  bool get isAvailable => api != null;

  /// `imported: lazer-audio.dll`, or null before an image is selected.
  String? get sourceDescription =>
      source == null ? null : '${source!.label}: $sourceLabel';

  /// True when network sources can be played: the engine reads them through the
  /// bridge's growing-file reader.
  bool get supportsStreaming => api != null && bridge != null;

  LazerAudioAvailability _withRejectedCandidates(List<String> rejected) =>
      rejected.isEmpty
      ? this
      : LazerAudioAvailability._(
          api: api,
          bridge: bridge,
          reason: reason,
          source: source,
          sourceLabel: sourceLabel,
          rejectedCandidates: List<String>.unmodifiable(rejected),
        );
}

/// Typed bindings for `lazer-audio`.
///
/// Blocking entry points are marked `blocking`: `open_*` reads the source (and
/// may wait for bytes), `queue_reader` decodes a successor, and `stop`,
/// `clear_queued_reader` and `destroy` join engine threads. They must not run on
/// the UI isolate; `LazerAudioWorker` owns them.
class LazerAudioApi {
  LazerAudioApi(this._library);

  final DynamicLibrary _library;

  late final int Function() abiVersion = _library
      .lookupFunction<Int32 Function(), int Function()>(
        'lazer_audio_abi_version',
      );

  late final Pointer<Void> Function(Pointer<LazerAudioEngineConfig>) create =
      _library.lookupFunction<
        Pointer<Void> Function(Pointer<LazerAudioEngineConfig>),
        Pointer<Void> Function(Pointer<LazerAudioEngineConfig>)
      >('lazer_audio_create');

  late final void Function(Pointer<Void>) destroy = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('lazer_audio_destroy');

  late final int Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Pointer<LazerAudioOpenParams>,
  )
  openFileUtf8 = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint8>,
          Pointer<LazerAudioOpenParams>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint8>,
          Pointer<LazerAudioOpenParams>,
        )
      >('lazer_audio_open_file_utf8');

  late final int Function(
    Pointer<Void>,
    Pointer<LazerAudioReader>,
    Pointer<LazerAudioOpenParams>,
  )
  openReader = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<LazerAudioReader>,
          Pointer<LazerAudioOpenParams>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<LazerAudioReader>,
          Pointer<LazerAudioOpenParams>,
        )
      >('lazer_audio_open_reader');

  late final int Function(
    Pointer<Void>,
    int,
    Pointer<LazerAudioReader>,
    Pointer<LazerAudioOpenParams>,
  )
  queueReader = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint64,
          Pointer<LazerAudioReader>,
          Pointer<LazerAudioOpenParams>,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<LazerAudioReader>,
          Pointer<LazerAudioOpenParams>,
        )
      >('lazer_audio_queue_reader');

  late final int Function(Pointer<Void>, int) clearQueuedReader = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint64),
        int Function(Pointer<Void>, int)
      >('lazer_audio_clear_queued_reader');

  /// ABI 31: clears exactly one named queue resource. The legacy call above is a
  /// different request — "drop whatever the queue holds now" — and is never
  /// implemented in terms of this one.
  late final int Function(Pointer<Void>, int, int, int) clearQueuedReaderEx =
      _library.lookupFunction<
        Int32 Function(Pointer<Void>, Uint64, Uint64, Int32),
        int Function(Pointer<Void>, int, int, int)
      >('lazer_audio_clear_queued_reader_ex');

  late final int Function()? _androidUsbBackendVersion = () {
    try {
      return _library.lookupFunction<Uint32 Function(), int Function()>(
        'lazer_audio_android_usb_backend_version',
      );
    } catch (_) {
      return null;
    }
  }();

  bool get supportsAndroidUsb => _androidUsbBackendVersion?.call() == 1;

  /// Optional: older imported libraries cannot safely cancel an audible mix.
  late final int Function(Pointer<Void>, int)? clearUnheardQueuedReader = () {
    try {
      return _library.lookupFunction<
        Int32 Function(Pointer<Void>, Uint64),
        int Function(Pointer<Void>, int)
      >('lazer_audio_clear_unheard_queued_reader');
    } catch (_) {
      return null;
    }
  }();

  late final int Function(Pointer<Void>) play = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('lazer_audio_play');

  late final int Function(Pointer<Void>) pause = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('lazer_audio_pause');

  late final int Function(Pointer<Void>) stop = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('lazer_audio_stop');

  late final int Function(Pointer<Void>, int) seek = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int64),
        int Function(Pointer<Void>, int)
      >('lazer_audio_seek');

  late final int Function(Pointer<Void>, double) setVolume = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Double),
        int Function(Pointer<Void>, double)
      >('lazer_audio_set_volume');

  /// Additive export: older imported engines can still play normally.
  late final int Function(Pointer<Void>, int)? setAutoMix = _optional(
    () =>
        _library.lookupFunction<
          Int32 Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)
        >('lazer_audio_set_automix'),
  );

  late final int Function(Pointer<Void>, Pointer<LazerAudioDspConfig>) setDsp =
      _library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<LazerAudioDspConfig>),
        int Function(Pointer<Void>, Pointer<LazerAudioDspConfig>)
      >('lazer_audio_set_dsp');

  late final int Function(Pointer<Void>, Pointer<LazerAudioDeviceConfig>)
  setDevice = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<LazerAudioDeviceConfig>),
        int Function(Pointer<Void>, Pointer<LazerAudioDeviceConfig>)
      >('lazer_audio_set_device');

  late final int Function(Pointer<Void>, Pointer<LazerAudioSnapshot>) snapshot =
      _library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<LazerAudioSnapshot>),
        int Function(Pointer<Void>, Pointer<LazerAudioSnapshot>)
      >('lazer_audio_snapshot');

  late final int Function(Pointer<Void>, Pointer<LazerAudioStreamInfo>)
  streamInfo = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<LazerAudioStreamInfo>),
        int Function(Pointer<Void>, Pointer<LazerAudioStreamInfo>)
      >('lazer_audio_stream_info');

  late final String Function(Pointer<Void>) lastError = () {
    final Pointer<Uint8> Function(Pointer<Void>) raw = _library
        .lookupFunction<
          Pointer<Uint8> Function(Pointer<Void>),
          Pointer<Uint8> Function(Pointer<Void>)
        >('lazer_audio_last_error');
    return (Pointer<Void> engine) => lazerReadCString(raw(engine));
  }();

  late final String Function() buildInformation = () {
    final Pointer<Uint8> Function() raw = _library
        .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
          'lazer_audio_build_information',
        );
    return () => lazerReadCString(raw(), maxBytes: 1 << 16);
  }();

  /// Owned log copies avoid retaining a native callback's temporary char*.
  /// Optional for imported libraries built before this additive ABI extension.
  late final int Function(Pointer<Void>, Pointer<Int32>, Pointer<Uint8>, int)?
  readLog = _optional(
    () =>
        _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Uint8>, Uint32),
          int Function(Pointer<Void>, Pointer<Int32>, Pointer<Uint8>, int)
        >('lazer_audio_read_log'),
  );

  /// Looks a symbol up and returns null when this platform does not export it.
  ///
  /// The catalogs are per platform: Windows exports the wide-character endpoint
  /// catalog plus the format/volume probes, Linux and macOS export the UTF-8 output
  /// catalog. Binding them as optional keeps one Dart surface for all three and makes
  /// a missing symbol a "not supported here" answer instead of an exception.
  T? _optional<T>(T Function() lookup) {
    try {
      return lookup();
    } on ArgumentError {
      return null;
    }
  }

  /// UTF-8 output catalog (Linux ALSA `hw:` PCMs, macOS CoreAudio UIDs).
  late final int Function(Pointer<Pointer<Void>>)? outputDeviceCatalogCreate =
      _optional<int Function(Pointer<Pointer<Void>>)>(
        () =>
            _library.lookupFunction<
              Int32 Function(Pointer<Pointer<Void>>),
              int Function(Pointer<Pointer<Void>>)
            >('lazer_audio_output_device_catalog_create'),
      );
  late final int Function(Pointer<Void>, Pointer<Uint32>)?
  outputDeviceCatalogCount =
      _optional<int Function(Pointer<Void>, Pointer<Uint32>)>(
        () =>
            _library.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Uint32>),
              int Function(Pointer<Void>, Pointer<Uint32>)
            >('lazer_audio_output_device_catalog_count'),
      );
  late final int Function(
    Pointer<Void>,
    int,
    Pointer<LazerAudioOutputDeviceInfo>,
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
  )?
  outputDeviceCatalogGet =
      _optional<
        int Function(
          Pointer<Void>,
          int,
          Pointer<LazerAudioOutputDeviceInfo>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
        )
      >(
        () =>
            _library.lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Uint32,
                Pointer<LazerAudioOutputDeviceInfo>,
                Pointer<Uint8>,
                Uint32,
                Pointer<Uint32>,
                Pointer<Uint8>,
                Uint32,
                Pointer<Uint32>,
                Pointer<Uint8>,
                Uint32,
                Pointer<Uint32>,
              ),
              int Function(
                Pointer<Void>,
                int,
                Pointer<LazerAudioOutputDeviceInfo>,
                Pointer<Uint8>,
                int,
                Pointer<Uint32>,
                Pointer<Uint8>,
                int,
                Pointer<Uint32>,
                Pointer<Uint8>,
                int,
                Pointer<Uint32>,
              )
            >('lazer_audio_output_device_catalog_get'),
      );
  late final void Function(Pointer<Void>)? outputDeviceCatalogDestroy =
      _optional<void Function(Pointer<Void>)>(
        () =>
            _library.lookupFunction<
              Void Function(Pointer<Void>),
              void Function(Pointer<Void>)
            >('lazer_audio_output_device_catalog_destroy'),
      );

  /// Windows render-endpoint catalog; strings are `wchar_t` (UTF-16), so buffers
  /// are `Uint16` and counts are UTF-16 code units.
  late final int Function(Pointer<Pointer<Void>>)? deviceCatalogCreate =
      _optional<int Function(Pointer<Pointer<Void>>)>(
        () =>
            _library.lookupFunction<
              Int32 Function(Pointer<Pointer<Void>>),
              int Function(Pointer<Pointer<Void>>)
            >('lazer_audio_device_catalog_create'),
      );
  late final int Function(Pointer<Void>, Pointer<Uint32>)? deviceCatalogCount =
      _optional<int Function(Pointer<Void>, Pointer<Uint32>)>(
        () =>
            _library.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Uint32>),
              int Function(Pointer<Void>, Pointer<Uint32>)
            >('lazer_audio_device_catalog_count'),
      );
  late final int Function(
    Pointer<Void>,
    int,
    Pointer<LazerAudioDeviceInfo>,
    Pointer<Uint16>,
    int,
    Pointer<Uint32>,
    Pointer<Uint16>,
    int,
    Pointer<Uint32>,
    Pointer<Uint16>,
    int,
    Pointer<Uint32>,
  )?
  deviceCatalogGet =
      _optional<
        int Function(
          Pointer<Void>,
          int,
          Pointer<LazerAudioDeviceInfo>,
          Pointer<Uint16>,
          int,
          Pointer<Uint32>,
          Pointer<Uint16>,
          int,
          Pointer<Uint32>,
          Pointer<Uint16>,
          int,
          Pointer<Uint32>,
        )
      >(
        () =>
            _library.lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Uint32,
                Pointer<LazerAudioDeviceInfo>,
                Pointer<Uint16>,
                Uint32,
                Pointer<Uint32>,
                Pointer<Uint16>,
                Uint32,
                Pointer<Uint32>,
                Pointer<Uint16>,
                Uint32,
                Pointer<Uint32>,
              ),
              int Function(
                Pointer<Void>,
                int,
                Pointer<LazerAudioDeviceInfo>,
                Pointer<Uint16>,
                int,
                Pointer<Uint32>,
                Pointer<Uint16>,
                int,
                Pointer<Uint32>,
                Pointer<Uint16>,
                int,
                Pointer<Uint32>,
              )
            >('lazer_audio_device_catalog_get'),
      );
  late final void Function(Pointer<Void>)? deviceCatalogDestroy =
      _optional<void Function(Pointer<Void>)>(
        () =>
            _library.lookupFunction<
              Void Function(Pointer<Void>),
              void Function(Pointer<Void>)
            >('lazer_audio_device_catalog_destroy'),
      );

  /// Exact-exclusive PCM format query for one Windows endpoint.
  late final int Function(
    Pointer<Uint16>,
    Pointer<LazerAudioPcmFormatCandidate>,
    int,
    Pointer<LazerAudioPcmFormatProbeResult>,
  )?
  probePcmFormats =
      _optional<
        int Function(
          Pointer<Uint16>,
          Pointer<LazerAudioPcmFormatCandidate>,
          int,
          Pointer<LazerAudioPcmFormatProbeResult>,
        )
      >(
        () =>
            _library.lookupFunction<
              Int32 Function(
                Pointer<Uint16>,
                Pointer<LazerAudioPcmFormatCandidate>,
                Uint32,
                Pointer<LazerAudioPcmFormatProbeResult>,
              ),
              int Function(
                Pointer<Uint16>,
                Pointer<LazerAudioPcmFormatCandidate>,
                int,
                Pointer<LazerAudioPcmFormatProbeResult>,
              )
            >('lazer_audio_device_probe_pcm_formats'),
      );

  /// Windows endpoint master volume; never software gain, never USB `SET_CUR`.
  late final int Function(
    Pointer<Uint16>,
    Pointer<Float>,
    Pointer<Uint32>,
    Pointer<Int32>,
  )?
  endpointVolumeGet =
      _optional<
        int Function(
          Pointer<Uint16>,
          Pointer<Float>,
          Pointer<Uint32>,
          Pointer<Int32>,
        )
      >(
        () =>
            _library.lookupFunction<
              Int32 Function(
                Pointer<Uint16>,
                Pointer<Float>,
                Pointer<Uint32>,
                Pointer<Int32>,
              ),
              int Function(
                Pointer<Uint16>,
                Pointer<Float>,
                Pointer<Uint32>,
                Pointer<Int32>,
              )
            >('lazer_audio_endpoint_volume_get'),
      );
  late final int Function(
    Pointer<Uint16>,
    double,
    Pointer<Uint32>,
    Pointer<Int32>,
  )?
  endpointVolumeSet =
      _optional<
        int Function(Pointer<Uint16>, double, Pointer<Uint32>, Pointer<Int32>)
      >(
        () =>
            _library.lookupFunction<
              Int32 Function(
                Pointer<Uint16>,
                Float,
                Pointer<Uint32>,
                Pointer<Int32>,
              ),
              int Function(
                Pointer<Uint16>,
                double,
                Pointer<Uint32>,
                Pointer<Int32>,
              )
            >('lazer_audio_endpoint_volume_set'),
      );
}

/// Typed bindings for `lazer-audio-bridge`, the growing-file reader.
class LazerAudioBridgeApi {
  LazerAudioBridgeApi(this._library) {
    // Bindings are lazy, but availability must reflect a usable reader rather
    // than merely a loadable image (including the linked image on iOS).
    for (final symbol in const [
      'lazer_bridge_reader_create',
      'lazer_bridge_reader_notify',
      'lazer_bridge_reader_finish',
      'lazer_bridge_reader_destroy',
      'lazer_bridge_reader_bytes_available',
      'lazer_bridge_reader_read',
      'lazer_bridge_reader_seek',
      'lazer_bridge_reader_length',
      'lazer_bridge_reader_close',
      'lazer_bridge_reader_cancel',
    ]) {
      if (!_library.providesSymbol(symbol)) {
        throw ArgumentError('reader bridge is missing $symbol');
      }
    }
  }

  final DynamicLibrary _library;

  late final int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>)
  readerCreate = _library
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Int64, Pointer<Pointer<Void>>),
        int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>)
      >('lazer_bridge_reader_create');

  late final void Function(Pointer<Void>) readerNotify = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('lazer_bridge_reader_notify');

  late final void Function(Pointer<Void>, int) readerFinish = _library
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('lazer_bridge_reader_finish');

  late final void Function(Pointer<Void>) readerDestroy = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('lazer_bridge_reader_destroy');

  late final void Function(Pointer<Void>) readerCancel = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('lazer_bridge_reader_cancel');

  late final int Function(Pointer<Void>) readerBytesAvailable = _library
      .lookupFunction<
        Int64 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('lazer_bridge_reader_bytes_available');

  /// Announces the track's size once the download learns it.
  ///
  /// A demuxer turns a seek's timestamp into the byte offset this reader is
  /// asked for through the source length, so an unknown length is what makes
  /// seeking a streaming track fail outright.
  late final void Function(Pointer<Void>, int)? readerSetLength =
      _optional<void Function(Pointer<Void>, int)>(
        () =>
            _library.lookupFunction<
              Void Function(Pointer<Void>, Int64),
              void Function(Pointer<Void>, int)
            >('lazer_bridge_reader_set_length'),
      );

  /// Looks a symbol up and returns null when this bridge does not export it.
  T? _optional<T>(T Function() lookup) {
    try {
      return lookup();
    } on ArgumentError {
      return null;
    }
  }

  /// Addresses of the five callbacks the engine invokes on its own threads.
  ///
  /// These are ordinary exported C functions, so they are taken with
  /// `DynamicLibrary.lookup` — the address of the function itself, not the result of
  /// calling it.
  late final Pointer<NativeFunction<LazerAudioReadNative>> readPointer =
      _library.lookup<NativeFunction<LazerAudioReadNative>>(
        'lazer_bridge_reader_read',
      );

  late final Pointer<NativeFunction<LazerAudioSeekNative>> seekPointer =
      _library.lookup<NativeFunction<LazerAudioSeekNative>>(
        'lazer_bridge_reader_seek',
      );

  late final Pointer<NativeFunction<LazerAudioLengthNative>> lengthPointer =
      _library.lookup<NativeFunction<LazerAudioLengthNative>>(
        'lazer_bridge_reader_length',
      );

  late final Pointer<NativeFunction<LazerAudioVoidNative>> closePointer =
      _library.lookup<NativeFunction<LazerAudioVoidNative>>(
        'lazer_bridge_reader_close',
      );

  late final Pointer<NativeFunction<LazerAudioVoidNative>> cancelPointer =
      _library.lookup<NativeFunction<LazerAudioVoidNative>>(
        'lazer_bridge_reader_cancel',
      );
}

/// The ABI entry points a load must find before the engine is offered at all.
///
/// The required ABI list gates the native loader. `lazer_audio_set_automix`,
/// `lazer_audio_read_log` and the device catalogs are additive: an engine
/// without them still plays, so they are looked up optionally instead of
/// gating the path.
const List<String> requiredEngineSymbols = <String>[
  // Called before the list is checked, because the version it returns decides
  // whether any other struct may be read at all.
  'lazer_audio_abi_version',
  'lazer_audio_create',
  'lazer_audio_destroy',
  'lazer_audio_open_file_utf8',
  'lazer_audio_open_reader',
  'lazer_audio_queue_reader',
  'lazer_audio_clear_queued_reader',
  // ABI 31: the reader release path. Without it a caller cannot prove that the
  // engine has stopped calling its reader, so the path is not offered at all.
  'lazer_audio_clear_queued_reader_ex',
  'lazer_audio_play',
  'lazer_audio_pause',
  'lazer_audio_stop',
  'lazer_audio_seek',
  'lazer_audio_set_volume',
  'lazer_audio_set_dsp',
  'lazer_audio_set_device',
  'lazer_audio_snapshot',
  'lazer_audio_stream_info',
  'lazer_audio_last_error',
  'lazer_audio_build_information',
];

/// Resolves and loads `lazer-audio` plus its reader bridge, once per process.
abstract final class LazerAudioLoader {
  /// Overrides the engine path; also honoured from the environment so a build
  /// tree can point at its own artifact without a rebuild of the Dart code.
  static const String libraryOverrideVariable = 'LAZER_AUDIO_LIBRARY';
  static const String bridgeOverrideVariable = 'LAZER_AUDIO_BRIDGE_LIBRARY';

  static LazerAudioAvailability? _cached;
  static String? importedLibraryPath;

  /// Validates one explicitly supplied image without falling back.
  ///
  /// Importing must reject a stale ABI even when the bundled engine could keep
  /// playback alive; otherwise the settings page stores an import that was
  /// never the image actually loaded.
  static LazerAudioAvailability inspect(String path) => _loadCandidate(
    File(path).absolute.uri,
    _bridgeFileNames,
    source: LazerAudioEngineSource.imported,
    sourceLabel: _basename(path),
  );

  /// Whether the host platform has an engine backend at all.
  ///
  /// Windows (WASAPI), Linux (ALSA), macOS (CoreAudio), and 64-bit Android
  /// (AAudio) use the native engine. iOS uses the platform audio plugin.
  static bool get isSupportedHost => _engineFileNames.isNotEmpty;

  /// File names to try, most specific first.
  ///
  /// MinGW prefixes DLLs with `lib` while MSVC does not, so both spellings are
  /// accepted on Windows; the POSIX names already carry the prefix.
  static List<String> get _engineFileNames => switch (Abi.current()) {
    Abi.windowsX64 ||
    Abi.windowsArm64 => <String>['lazer-audio.dll', 'liblazer-audio.dll'],
    Abi.linuxX64 ||
    Abi.linuxArm64 ||
    Abi.androidArm64 ||
    Abi.androidX64 => <String>['liblazer-audio.so'],
    Abi.macosX64 || Abi.macosArm64 => <String>['liblazer-audio.dylib'],
    _ => const <String>[],
  };

  static List<String> get _bridgeFileNames => switch (Abi.current()) {
    Abi.windowsX64 || Abi.windowsArm64 => <String>[
      'lazer-audio-bridge.dll',
      'liblazer-audio-bridge.dll',
    ],
    Abi.linuxX64 ||
    Abi.linuxArm64 ||
    Abi.androidArm64 ||
    Abi.androidX64 => <String>['liblazer-audio-bridge.so'],
    Abi.macosX64 || Abi.macosArm64 => <String>['liblazer-audio-bridge.dylib'],
    _ => const <String>[],
  };

  /// Loads (and caches) the engine. Never throws: a missing library, a missing
  /// dependency or an ABI mismatch all come back as an unavailable report.
  static LazerAudioAvailability load({bool reload = false}) {
    final LazerAudioAvailability? cached = _cached;
    if (cached != null && !reload) return cached;
    final LazerAudioAvailability result = _load();
    _cached = result;
    return result;
  }

  static LazerAudioAvailability _load() {
    if (!Platform.isWindows &&
        !Platform.isLinux &&
        !Platform.isMacOS &&
        !Platform.isAndroid) {
      return const LazerAudioAvailability.unavailable(
        'this platform has no native audio backend',
      );
    }
    final List<String> engineFileNames = _engineFileNames;
    final List<String> bridgeFileNames = _bridgeFileNames;
    if (engineFileNames.isEmpty || bridgeFileNames.isEmpty) {
      return LazerAudioAvailability.unavailable(
        'unsupported architecture ${Abi.current()}',
      );
    }
    final String? explicitPath = importedLibraryPath?.trim();
    final String? environmentOverride = Platform
        .environment[libraryOverrideVariable]
        ?.trim();
    final List<String> missingPreferences = <String>[
      for (final ({String? path, LazerAudioEngineSource source}) preference
          in <({String? path, LazerAudioEngineSource source})>[
            (path: explicitPath, source: LazerAudioEngineSource.imported),
            (
              path: environmentOverride,
              source: LazerAudioEngineSource.environment,
            ),
          ])
        if (preference.path != null &&
            preference.path!.isNotEmpty &&
            !File(preference.path!).existsSync())
          '${preference.source.label} engine '
              '${_basename(preference.path!)} was not found; it was ignored',
    ];
    final enginePaths = _paths.candidates(
      fileNames: engineFileNames,
      environmentOverride: environmentOverride,
      explicitPath: explicitPath,
    );
    return selectFirstUsable(
      enginePaths,
      (Uri path) => _loadCandidate(
        path,
        bridgeFileNames,
        source: _preferredSource(path, explicitPath, environmentOverride),
        sourceLabel: _basename(path.toFilePath()),
      ),
      unavailableReason:
          '${engineFileNames.first} was not found in the app bundle, '
          'configured override, or development checkout',
      initialRejections: missingPreferences,
      onRejected: (String reason) => developer.log(reason, name: 'lazer-audio'),
    );
  }

  static LazerAudioEngineSource _preferredSource(
    Uri candidate,
    String? explicitPath,
    String? environmentOverride,
  ) {
    if (explicitPath != null &&
        explicitPath.isNotEmpty &&
        File(explicitPath).absolute.uri == candidate) {
      return LazerAudioEngineSource.imported;
    }
    if (environmentOverride != null &&
        environmentOverride.isNotEmpty &&
        File(environmentOverride).absolute.uri == candidate) {
      return LazerAudioEngineSource.environment;
    }
    return LazerAudioEngineSource.bundled;
  }

  static String _basename(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int slash = normalized.lastIndexOf('/');
    final String name = slash < 0
        ? normalized
        : normalized.substring(slash + 1);
    return name.isEmpty ? 'lazer-audio' : name;
  }

  /// Tries every candidate in order and keeps the failed ones as diagnostics.
  ///
  /// Exposed for tests: the fallback itself is plain orchestration, so it can
  /// be proven without corrupting a real shared library or depending on a
  /// developer build tree.
  static LazerAudioAvailability selectFirstUsable(
    Iterable<Uri> candidates,
    LazerAudioAvailability Function(Uri candidate) probe, {
    required String unavailableReason,
    Iterable<String> initialRejections = const <String>[],
    void Function(String reason)? onRejected,
  }) {
    final failures = <String>[...initialRejections];
    for (final String reason in initialRejections) {
      onRejected?.call(reason);
    }
    for (final Uri candidate in candidates) {
      final availability = probe(candidate);
      if (availability.isAvailable) {
        return availability._withRejectedCandidates(failures);
      }
      final reason = availability.reason!;
      failures.add(reason);
      onRejected?.call(reason);
    }
    return LazerAudioAvailability.unavailable(
      failures.isEmpty ? unavailableReason : failures.join('\n'),
      rejectedCandidates: failures.isEmpty
          ? const <String>[]
          : List<String>.unmodifiable(failures),
    );
  }

  static LazerAudioAvailability _loadCandidate(
    Uri enginePath,
    List<String> bridgeFileNames, {
    required LazerAudioEngineSource source,
    required String sourceLabel,
  }) {
    final String engineFileName = '${source.label} engine $sourceLabel';
    // Windows resolves a native library's own dependencies through the *process*
    // search path, not the directory the library was opened from, so a build tree
    // that keeps FFmpeg's DLLs beside the engine still fails with "module could
    // not be found" (error 126). Loading them first puts them in the process, which
    // is what makes both a staged `build/native-audio` and a `flutter run` from the
    // repository root work. A packaged bundle has them next to the executable
    // already, and the attempt is harmless there.
    _preloadDependencies(enginePath);
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(enginePath.toFilePath());
    } catch (error) {
      return LazerAudioAvailability.unavailable(
        'loading $engineFileName failed: '
        '${_safeError(error, enginePath, sourceLabel)}',
      );
    }
    final LazerAudioApi api = LazerAudioApi(library);
    final int version;
    try {
      version = api.abiVersion();
    } catch (error) {
      return LazerAudioAvailability.unavailable(
        '$engineFileName does not export the lazer-audio ABI: '
        '${_safeError(error, enginePath, sourceLabel)}',
      );
    }
    if (version != lazerAudioAbiVersion) {
      return LazerAudioAvailability.unavailable(
        '$engineFileName reports ABI $version; this build expects '
        '$lazerAudioAbiVersion. Rebuild the engine from this checkout '
        '(dart run tool/build_native_audio.dart) or import a matching engine.',
      );
    }
    // Every symbol at once, not the first one that is absent: on iOS the engine
    // is force-loaded into the executable, so a missing entry point means the
    // linker dropped the export trie (`-export_dynamic`) or an archive member was
    // not pulled in. Reporting one name at a time turned that into a sequence of
    // rebuilds, so the whole missing set travels in the reason the settings page
    // and the log show.
    final List<String> missingSymbols = <String>[
      for (final String symbol in requiredEngineSymbols)
        if (!api._library.providesSymbol(symbol)) symbol,
    ];
    if (missingSymbols.isNotEmpty) {
      return LazerAudioAvailability.unavailable(
        '$engineFileName is missing ${missingSymbols.length} of '
        '${requiredEngineSymbols.length} ABI symbols: '
        '${missingSymbols.join(', ')}',
      );
    }
    // The bridge is optional: without it the engine still plays local files,
    // it just cannot stream. A load failure is reported through
    // `supportsStreaming` rather than downgrading the whole engine.
    LazerAudioBridgeApi? bridge;
    final Uri? bridgePath = _resolve(
      fileNames: bridgeFileNames,
      environmentVariable: bridgeOverrideVariable,
      siblingDirectory: File(enginePath.toFilePath()).parent.path,
    );
    if (bridgePath != null) {
      try {
        bridge = LazerAudioBridgeApi(
          DynamicLibrary.open(bridgePath.toFilePath()),
        );
      } catch (error) {
        developer.log(
          'reader bridge for $engineFileName could not be loaded: '
          '${_safeError(error, bridgePath, _basename(bridgePath.toFilePath()))}',
          name: 'lazer-audio',
        );
      }
    }
    return LazerAudioAvailability.available(
      api,
      bridge,
      source: source,
      sourceLabel: sourceLabel,
    );
  }

  /// Replaces the selected image's absolute path before text reaches a log or
  /// the settings page. Error messages from the platform loader otherwise carry
  /// the user's full local path.
  static String _safeError(Object error, Uri? path, String label) {
    String text = '$error';
    if (path != null) {
      text = text.replaceAll(path.toFilePath(), label);
    }
    return text;
  }

  /// Kept alive for the process lifetime: dropping these would unload the modules
  /// the engine depends on.
  static final List<DynamicLibrary> _preloadedDependencies = <DynamicLibrary>[];

  /// Root development engines keep their FFmpeg runtime under build/native-audio;
  /// bundles and imports resolve dependencies beside the selected engine.
  static void _preloadDependencies(Uri enginePath) {
    if (!Platform.isWindows) return;
    const List<String> order = <String>[
      'avutil',
      'swresample',
      'avcodec',
      'avformat',
    ];
    final List<File> candidates = <File>[];
    for (final directory in _paths.dependencyDirectories(enginePath)) {
      if (!directory.existsSync()) continue;
      try {
        candidates.addAll(
          directory.listSync().whereType<File>().where(
            (File file) => file.path.toLowerCase().endsWith('.dll'),
          ),
        );
      } catch (error) {
        developer.log(
          'listing an audio dependency directory failed: '
          '${_safeError(error, null, '')}',
          name: 'lazer-audio',
        );
      }
    }
    for (final String library in order) {
      for (final File file in candidates) {
        final String name = file.uri.pathSegments.last.toLowerCase();
        if (!name.startsWith('$library-') && !name.startsWith('${library}_')) {
          continue;
        }
        try {
          _preloadedDependencies.add(DynamicLibrary.open(file.path));
          break;
        } catch (error) {
          final String name = _basename(file.path);
          developer.log(
            'preloading $name failed: '
            '${_safeError(error, file.uri, name)}',
            name: 'lazer-audio',
          );
        }
      }
    }
  }

  static NativeAudioLibraryPaths get _paths => NativeAudioLibraryPaths(
    workingDirectory: Directory.current,
    executableDirectory: File(Platform.resolvedExecutable).parent,
    development: !const bool.fromEnvironment('dart.vm.product'),
    linux: Platform.isLinux,
    android: Platform.isAndroid,
  );

  /// Imports and environment overrides take precedence. Development checkouts
  /// prefer the staged engine; installed apps use their own bundle.
  static Uri? _resolve({
    required List<String> fileNames,
    required String environmentVariable,
    String? explicitPath,
    String? siblingDirectory,
  }) => _paths.resolve(
    fileNames: fileNames,
    explicitPath: explicitPath,
    environmentOverride: Platform.environment[environmentVariable],
    siblingDirectory: siblingDirectory,
  );
}
