// Loading and binding of the native `lazer-audio` engine and its reader bridge.
//
// The engine is a single C ABI shared library (`lazer_audio_api.h`, ABI v23);
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

/// Result of trying to load the engine.
///
/// [api] is non-null only when both the library and the ABI version matched, so
/// callers can branch on `api != null` instead of catching.
///
/// Deliberately free of Flutter imports: the loader is exercised by plain-Dart
/// checks (`tool/`), where the Flutter SDK is not available.
class LazerAudioAvailability {
  const LazerAudioAvailability._({this.api, this.bridge, this.reason});

  const LazerAudioAvailability.unavailable(String reason)
    : this._(reason: reason);

  const LazerAudioAvailability.available(
    LazerAudioApi api,
    LazerAudioBridgeApi? bridge,
  ) : this._(api: api, bridge: bridge);

  final LazerAudioApi? api;
  final LazerAudioBridgeApi? bridge;

  /// Why the engine cannot be used; null when it can.
  final String? reason;

  bool get isAvailable => api != null;

  /// True when network sources can be played: the engine reads them through the
  /// bridge's growing-file reader.
  bool get supportsStreaming => api != null && bridge != null;
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
      _library
          .lookupFunction<
            Pointer<Void> Function(Pointer<LazerAudioEngineConfig>),
            Pointer<Void> Function(Pointer<LazerAudioEngineConfig>)
          >('lazer_audio_create');

  late final void Function(Pointer<Void>) destroy = _library
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
        'lazer_audio_destroy',
      );

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<LazerAudioOpenParams>)
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

  late final int Function(Pointer<Void>) play = _library
      .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'lazer_audio_play',
      );

  late final int Function(Pointer<Void>) pause = _library
      .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'lazer_audio_pause',
      );

  late final int Function(Pointer<Void>) stop = _library
      .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'lazer_audio_stop',
      );

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

  late final int Function(Pointer<Void>, Pointer<LazerAudioDspConfig>) setDsp =
      _library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<LazerAudioDspConfig>),
            int Function(Pointer<Void>, Pointer<LazerAudioDspConfig>)
          >('lazer_audio_set_dsp');

  late final int Function(
    Pointer<Void>,
    Pointer<LazerAudioDeviceConfig>,
  )
  setDevice = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<LazerAudioDeviceConfig>),
        int Function(Pointer<Void>, Pointer<LazerAudioDeviceConfig>)
      >('lazer_audio_set_device');

  late final int Function(Pointer<Void>, Pointer<LazerAudioSnapshot>) snapshot =
      _library
          .lookupFunction<
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
  late final int Function(Pointer<Pointer<Void>>)? outputDeviceCatalogCreate = _optional<int Function(Pointer<Pointer<Void>>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Pointer<Void>>), int Function(Pointer<Pointer<Void>>)>('lazer_audio_output_device_catalog_create'),
  );
  late final int Function(Pointer<Void>, Pointer<Uint32>)? outputDeviceCatalogCount = _optional<int Function(Pointer<Void>, Pointer<Uint32>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, Pointer<Uint32>)>('lazer_audio_output_device_catalog_count'),
  );
  late final int Function(Pointer<Void>, int, Pointer<LazerAudioOutputDeviceInfo>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>)? outputDeviceCatalogGet = _optional<int Function(Pointer<Void>, int, Pointer<LazerAudioOutputDeviceInfo>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<LazerAudioOutputDeviceInfo>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint8>, Uint32, Pointer<Uint32>), int Function(Pointer<Void>, int, Pointer<LazerAudioOutputDeviceInfo>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>)>('lazer_audio_output_device_catalog_get'),
  );
  late final void Function(Pointer<Void>)? outputDeviceCatalogDestroy = _optional<void Function(Pointer<Void>)>(
    () => _library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('lazer_audio_output_device_catalog_destroy'),
  );
  /// Windows render-endpoint catalog; strings are `wchar_t` (UTF-16), so buffers
  /// are `Uint16` and counts are UTF-16 code units.
  late final int Function(Pointer<Pointer<Void>>)? deviceCatalogCreate = _optional<int Function(Pointer<Pointer<Void>>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Pointer<Void>>), int Function(Pointer<Pointer<Void>>)>('lazer_audio_device_catalog_create'),
  );
  late final int Function(Pointer<Void>, Pointer<Uint32>)? deviceCatalogCount = _optional<int Function(Pointer<Void>, Pointer<Uint32>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, Pointer<Uint32>)>('lazer_audio_device_catalog_count'),
  );
  late final int Function(Pointer<Void>, int, Pointer<LazerAudioDeviceInfo>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint16>, int, Pointer<Uint32>)? deviceCatalogGet = _optional<int Function(Pointer<Void>, int, Pointer<LazerAudioDeviceInfo>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint16>, int, Pointer<Uint32>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<LazerAudioDeviceInfo>, Pointer<Uint16>, Uint32, Pointer<Uint32>, Pointer<Uint16>, Uint32, Pointer<Uint32>, Pointer<Uint16>, Uint32, Pointer<Uint32>), int Function(Pointer<Void>, int, Pointer<LazerAudioDeviceInfo>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint16>, int, Pointer<Uint32>)>('lazer_audio_device_catalog_get'),
  );
  late final void Function(Pointer<Void>)? deviceCatalogDestroy = _optional<void Function(Pointer<Void>)>(
    () => _library.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('lazer_audio_device_catalog_destroy'),
  );
  /// Exact-exclusive PCM format query for one Windows endpoint.
  late final int Function(Pointer<Uint16>, Pointer<LazerAudioPcmFormatCandidate>, int, Pointer<LazerAudioPcmFormatProbeResult>)? probePcmFormats = _optional<int Function(Pointer<Uint16>, Pointer<LazerAudioPcmFormatCandidate>, int, Pointer<LazerAudioPcmFormatProbeResult>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Uint16>, Pointer<LazerAudioPcmFormatCandidate>, Uint32, Pointer<LazerAudioPcmFormatProbeResult>), int Function(Pointer<Uint16>, Pointer<LazerAudioPcmFormatCandidate>, int, Pointer<LazerAudioPcmFormatProbeResult>)>('lazer_audio_device_probe_pcm_formats'),
  );
  /// Windows endpoint master volume; never software gain, never USB `SET_CUR`.
  late final int Function(Pointer<Uint16>, Pointer<Float>, Pointer<Uint32>, Pointer<Int32>)? endpointVolumeGet = _optional<int Function(Pointer<Uint16>, Pointer<Float>, Pointer<Uint32>, Pointer<Int32>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Uint16>, Pointer<Float>, Pointer<Uint32>, Pointer<Int32>), int Function(Pointer<Uint16>, Pointer<Float>, Pointer<Uint32>, Pointer<Int32>)>('lazer_audio_endpoint_volume_get'),
  );
  late final int Function(Pointer<Uint16>, double, Pointer<Uint32>, Pointer<Int32>)? endpointVolumeSet = _optional<int Function(Pointer<Uint16>, double, Pointer<Uint32>, Pointer<Int32>)>(
    () => _library.lookupFunction<Int32 Function(Pointer<Uint16>, Float, Pointer<Uint32>, Pointer<Int32>), int Function(Pointer<Uint16>, double, Pointer<Uint32>, Pointer<Int32>)>('lazer_audio_endpoint_volume_set'),
  );
}

/// Typed bindings for `lazer-audio-bridge`, the growing-file reader.
class LazerAudioBridgeApi {
  LazerAudioBridgeApi(this._library);

  final DynamicLibrary _library;

  late final int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>)
  readerCreate = _library
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Int64, Pointer<Pointer<Void>>),
        int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>)
      >('lazer_bridge_reader_create');

  late final void Function(Pointer<Void>) readerNotify = _library
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
        'lazer_bridge_reader_notify',
      );

  late final void Function(Pointer<Void>, int) readerFinish = _library
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('lazer_bridge_reader_finish');

  late final void Function(Pointer<Void>) readerDestroy = _library
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
        'lazer_bridge_reader_destroy',
      );

  late final int Function(Pointer<Void>) readerBytesAvailable = _library
      .lookupFunction<Int64 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'lazer_bridge_reader_bytes_available',
      );

  /// Addresses of the five callbacks the engine invokes on its own threads.
  ///
  /// These are ordinary exported C functions, so they are taken with
  /// `DynamicLibrary.lookup` — the address of the function itself, not the result of
  /// calling it.
  late final Pointer<NativeFunction<LazerAudioReadNative>> readPointer = _library
      .lookup<NativeFunction<LazerAudioReadNative>>('lazer_bridge_reader_read');

  late final Pointer<NativeFunction<LazerAudioSeekNative>> seekPointer = _library
      .lookup<NativeFunction<LazerAudioSeekNative>>('lazer_bridge_reader_seek');

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

/// Resolves and loads `lazer-audio` plus its reader bridge, once per process.
abstract final class LazerAudioLoader {
  /// Overrides the engine path; also honoured from the environment so a build
  /// tree can point at its own artifact without a rebuild of the Dart code.
  static const String libraryOverrideVariable = 'LAZER_AUDIO_LIBRARY';
  static const String bridgeOverrideVariable = 'LAZER_AUDIO_BRIDGE_LIBRARY';

  static LazerAudioAvailability? _cached;

  /// Whether the host platform has an engine backend at all.
  ///
  /// Windows (WASAPI), Linux (ALSA) and macOS (CoreAudio) do. Android and iOS
  /// need the JNI path from the master branch, which this port does not wire up
  /// yet, so they always report unavailable and the app keeps `just_audio`.
  static bool get isSupportedHost => _engineFileNames.isNotEmpty;

  /// File names to try, most specific first.
  ///
  /// MinGW prefixes DLLs with `lib` while MSVC does not, so both spellings are
  /// accepted on Windows; the POSIX names already carry the prefix.
  static List<String> get _engineFileNames => switch (Abi.current()) {
    Abi.windowsX64 || Abi.windowsArm64 => <String>[
      'lazer-audio.dll',
      'liblazer-audio.dll',
    ],
    Abi.linuxX64 || Abi.linuxArm64 => <String>['liblazer-audio.so'],
    Abi.macosX64 || Abi.macosArm64 => <String>['liblazer-audio.dylib'],
    _ => const <String>[],
  };

  static List<String> get _bridgeFileNames => switch (Abi.current()) {
    Abi.windowsX64 || Abi.windowsArm64 => <String>[
      'lazer-audio-bridge.dll',
      'liblazer-audio-bridge.dll',
    ],
    Abi.linuxX64 || Abi.linuxArm64 => <String>['liblazer-audio-bridge.so'],
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
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
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
    final Uri? enginePath = _resolve(
      fileNames: engineFileNames,
      environmentVariable: libraryOverrideVariable,
    );
    if (enginePath == null) {
      return LazerAudioAvailability.unavailable(
        '${engineFileNames.first} was not found next to the executable, in the '
        'working directory, or in build/native',
      );
    }
    final String engineFileName = enginePath.pathSegments.last;
    // Windows resolves a native library's own dependencies through the *process*
    // search path, not the directory the library was opened from, so a build tree
    // that keeps FFmpeg's DLLs beside the engine still fails with "module could
    // not be found" (error 126). Loading them first puts them in the process, which
    // is what makes both a staged `build/native-audio` and a `flutter run` from the
    // repository root work. A packaged bundle has them next to the executable
    // already, and the attempt is harmless there.
    _preloadDependencies(enginePath);
    final LazerAudioApi api;
    try {
      api = LazerAudioApi(DynamicLibrary.open(enginePath.toFilePath()));
    } catch (error) {
      return LazerAudioAvailability.unavailable(
        'loading $engineFileName failed: $error',
      );
    }
    final int version;
    try {
      version = api.abiVersion();
    } catch (error) {
      return LazerAudioAvailability.unavailable(
        '$engineFileName does not export the lazer-audio ABI: $error',
      );
    }
    if (version != lazerAudioAbiVersion) {
      return LazerAudioAvailability.unavailable(
        '$engineFileName reports ABI $version; this build expects '
        '$lazerAudioAbiVersion',
      );
    }
    // The bridge is optional: without it the engine still plays local files,
    // it just cannot stream. A load failure is reported through
    // `supportsStreaming` rather than downgrading the whole engine.
    LazerAudioBridgeApi? bridge;
    final Uri? bridgePath = _resolve(
      fileNames: bridgeFileNames,
      environmentVariable: bridgeOverrideVariable,
    );
    if (bridgePath != null) {
      try {
        bridge = LazerAudioBridgeApi(
          DynamicLibrary.open(bridgePath.toFilePath()),
        );
      } catch (error) {
        developer.log('bridge load failed: $error', name: 'lazer-audio');
      }
    }
    return LazerAudioAvailability.available(api, bridge);
  }

  /// Kept alive for the process lifetime: dropping these would unload the modules
  /// the engine depends on.
  static final List<DynamicLibrary> _preloadedDependencies = <DynamicLibrary>[];

  /// Loads the FFmpeg libraries that sit next to [enginePath], in dependency order
  /// (codecs before the demuxer that uses them). Failures are ignored: the engine
  /// may still load if the DLLs are found another way.
  static void _preloadDependencies(Uri enginePath) {
    if (!Platform.isWindows) return;
    final Directory directory = File(enginePath.toFilePath()).parent;
    if (!directory.existsSync()) return;
    const List<String> order = <String>[
      'avutil',
      'swresample',
      'avcodec',
      'avformat',
    ];
    final List<File> candidates = <File>[];
    try {
      candidates.addAll(
        directory
            .listSync()
            .whereType<File>()
            .where((File file) => file.path.toLowerCase().endsWith('.dll')),
      );
    } catch (error) {
      developer.log('listing $directory failed: $error', name: 'lazer-audio');
      return;
    }
    for (final String library in order) {
      for (final File file in candidates) {
        final String name = file.uri.pathSegments.last.toLowerCase();
        if (!name.startsWith('$library-') && !name.startsWith('${library}_')) {
          continue;
        }
        try {
          _preloadedDependencies.add(DynamicLibrary.open(file.path));
        } catch (error) {
          developer.log(
            'preloading ${file.path} failed: $error',
            name: 'lazer-audio',
          );
        }
      }
    }
  }

  /// Resolution order: explicit environment override, the executable's own
  /// directory (a packaged bundle), the working directory (a `flutter run` from
  /// the repo root), then the trees `tool/build_native_audio.dart` and CMake
  /// produce under `build/native-audio`.
  static Uri? _resolve({
    required List<String> fileNames,
    required String environmentVariable,
  }) {
    final String? override = Platform.environment[environmentVariable];
    if (override != null && override.trim().isNotEmpty) {
      final File file = File(override.trim());
      if (file.existsSync()) return file.absolute.uri;
    }
    final String separator = Platform.pathSeparator;
    final String cwd = Directory.current.path;
    final List<String> directories = <String>[
      File(Platform.resolvedExecutable).parent.path,
      cwd,
    ];
    // Multi-config generators nest artefacts under a configuration directory and
    // each CMake target gets its own output directory.
    for (final String root in <String>[
      'build/native-audio',
      'build/native',
    ]) {
      for (final String subdirectory in <String>[
        '',
        'lazer-audio',
        'lazer-audio-bridge',
      ]) {
        for (final String configuration in <String>[
          '',
          'Release',
          'Debug',
        ]) {
          directories.add(
            <String>[cwd, root, subdirectory, configuration]
                .where((String part) => part.isNotEmpty)
                .join(separator),
          );
        }
      }
    }
    for (final String directory in directories) {
      for (final String fileName in fileNames) {
        final File candidate = File(
          <String>[directory, fileName].join(Platform.pathSeparator),
        );
        if (candidate.existsSync()) return candidate.absolute.uri;
      }
    }
    return null;
  }
}
