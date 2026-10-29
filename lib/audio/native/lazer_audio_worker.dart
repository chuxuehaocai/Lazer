// A dedicated isolate for the engine calls that block.
//
// `lazer_audio_open_reader` reads (and waits for) the source, `queue_reader`
// decodes a successor, and `stop`/`clear_queued_reader`/`destroy` join engine
// threads. Running those on the UI isolate freezes the frame loop for as long as
// the demuxer needs bytes — on a network source that is tens to hundreds of
// milliseconds per track change. The master branch ran them on `Dispatchers.IO`
// for the same reason; here they run in a worker isolate.
//
// The worker also serialises them: one isolate, one event loop, so a device
// change can never overtake the open it was meant for.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'lazer_audio_abi.dart';
import 'lazer_audio_library.dart';

/// One equaliser band, in the shape the ABI takes.
class LazerEqBandSettings {
  const LazerEqBandSettings({
    this.kind = lazerAudioEqBandPeak,
    this.frequencyHz = 1000,
    this.gainDb = 0,
    this.q = 1,
    this.enabled = true,
  });

  final int kind;
  final double frequencyHz;
  final double gainDb;
  final double q;
  final bool enabled;

  List<Object?> toMessage() => <Object?>[
    kind,
    frequencyHz,
    gainDb,
    q,
    enabled ? 1 : 0,
  ];
}

/// Cross-channel feed for headphone listening (`LazerAudioDspConfig.crossfeed_*`).
///
/// The named algorithms (Bauer, Bs2b, Meier) fix their own delay and cutoff; only
/// [custom] uses [delayMs] and [cutoffHz].
class LazerCrossfeedSettings {
  const LazerCrossfeedSettings({
    this.enabled = false,
    this.strength = 0,
    this.algorithm = LazerAudioCrossfeedAlgorithm.custom,
    this.delayMs = 0.22,
    this.cutoffHz = 700,
  });

  final bool enabled;

  /// 0..1; below 0.0001 the engine treats it as off.
  final double strength;

  /// `LazerAudioCrossfeedAlgorithm`.
  final int algorithm;

  final double delayMs;
  final double cutoffHz;

  List<Object?> toMessage() => <Object?>[
    enabled ? 1 : 0,
    strength.clamp(0, 1),
    algorithm,
    delayMs,
    cutoffHz,
  ];
}

/// Output settings for the next opened stream.
class LazerDeviceSettings {
  const LazerDeviceSettings({
    this.exclusive = false,
    this.bitPerfect = false,
    this.resampleMode = lazerAudioResampleNative,
    this.targetSampleRate = 0,
    this.bufferMillis = 120,
    this.dsdOutputMode = lazerAudioDsdOutputConvertToPcm,
    this.dsdFallbackChain,
    this.deviceToken,
  });

  final bool exclusive;
  final bool bitPerfect;
  final int resampleMode;
  final int targetSampleRate;
  final int bufferMillis;

  /// The engine policy to open with first.
  final int dsdOutputMode;

  /// Ordered engine policies to try when [dsdOutputMode] is refused.
  ///
  /// The engine itself has no "auto" DSD mode: it accepts one explicit policy per
  /// open and refuses rather than downgrading. The settings layer owns the policy
  /// meaning and hands the order over as plain engine values, so this layer stays
  /// independent of it. Null or a single entry means "no fallback".
  final List<int>? dsdFallbackChain;

  /// The output device token from `lazer_audio_output_device_catalog_get`.
  ///
  /// The C struct carries a `wchar_t *` that only Windows reads, so this port
  /// always asks the engine for its default endpoint and keeps the token as
  /// diagnostics rather than pretending to select a device.
  final String? deviceToken;

  /// The six fields the ABI's device struct holds.
  List<Object?> toDeviceMessage() => <Object?>[
    exclusive ? 1 : 0,
    resampleMode,
    targetSampleRate,
    bufferMillis,
    bitPerfect ? 1 : 0,
    dsdOutputMode,
  ];

  /// The ordered policies to attempt, always starting with [dsdOutputMode].
  List<int> get dsdAttempts {
    final List<int> chain = dsdFallbackChain ?? const <int>[];
    if (chain.isEmpty) return <int>[dsdOutputMode];
    return chain.first == dsdOutputMode
        ? chain
        : <int>[dsdOutputMode, ...chain];
  }

  List<Object?> toMessage() => <Object?>[...toDeviceMessage(), deviceToken];
}

/// Per-source open parameters.
class LazerOpenSettings {
  const LazerOpenSettings({
    this.start = Duration.zero,
    this.durationHint,
    this.cueStartFrame75 = 0,
    this.cueEndFrame75 = 0,
    this.replayGainDb = 0,
  });

  final Duration start;
  final Duration? durationHint;
  final int cueStartFrame75;
  final int cueEndFrame75;
  final double replayGainDb;

  List<Object?> toMessage() => <Object?>[
    start.inMilliseconds,
    durationHint?.inMilliseconds ?? 0,
    cueStartFrame75,
    cueEndFrame75,
    replayGainDb,
  ];
}

/// Commands the worker executes; keep in sync with `_execute`.
abstract final class LazerWorkerOp {
  static const int create = 0;
  static const int destroy = 1;
  static const int openFile = 2;
  static const int openReader = 3;
  static const int queueReader = 4;
  static const int clearQueuedReader = 5;
  static const int stop = 6;
  static const int setDevice = 7;
  static const int setVolume = 8;
  static const int setDsp = 9;
}

/// The owning side of the worker isolate.
class LazerAudioWorker {
  LazerAudioWorker._(
    this._isolate,
    this._replies,
    this._sendPort,
    this._pending,
  );

  final Isolate _isolate;
  final ReceivePort _replies;
  final SendPort _sendPort;
  final Map<int, Completer<Object?>> _pending;
  int _nextId = 1;
  bool _closed = false;

  /// Spawns the worker and waits until it has the engine library loaded.
  ///
  /// Throws when the library cannot be loaded inside the isolate, so the caller
  /// can fall back to the platform engine instead of failing playback later.
  static Future<LazerAudioWorker> spawn() async {
    final ReceivePort replies = ReceivePort();
    final Completer<SendPort> ready = Completer<SendPort>();
    final Completer<String> startupFailure = Completer<String>();
    final Map<int, Completer<Object?>> pending = <int, Completer<Object?>>{};

    void failPending(String reason) {
      for (final Completer<Object?> completer in pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(StateError(reason));
        }
      }
      pending.clear();
    }

    final Isolate isolate = await Isolate.spawn<_WorkerStart>(
      _workerMain,
      _WorkerStart(replies.sendPort),
      debugName: 'lazer-audio-worker',
      onError: replies.sendPort,
      onExit: replies.sendPort,
    );

    replies.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is List && message.isNotEmpty && message.first is int) {
        final List<Object?> reply = message.cast<Object?>();
        final Completer<Object?>? completer = pending.remove(reply[0]);
        if (completer == null || completer.isCompleted) return;
        final String? error = reply.length > 2 ? reply[2] as String? : null;
        if (error != null) {
          completer.completeError(StateError(error));
        } else {
          completer.complete(reply.length > 1 ? reply[1] : null);
        }
        return;
      }
      if (message is List && message.isNotEmpty && message.first is String) {
        // Either the worker could not load the engine, or the isolate crashed.
        final String reason = message.first as String;
        if (!startupFailure.isCompleted) startupFailure.complete(reason);
        if (ready.isCompleted) failPending(reason);
      }
    });

    try {
      final SendPort sendPort = await Future.any<SendPort>(<Future<SendPort>>[
        ready.future,
        startupFailure.future.then<SendPort>(
          (String reason) => throw StateError(
            'the lazer-audio worker could not start: $reason',
          ),
        ),
      ]);
      return LazerAudioWorker._(isolate, replies, sendPort, pending);
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      rethrow;
    }
  }

  /// Runs one command on the worker and waits for its result.
  ///
  /// Throws [StateError] when the worker closed or the native call failed.
  Future<Object?> call(int op, List<Object?> params) {
    if (_closed) {
      return Future<Object?>.error(StateError('the audio worker is closed'));
    }
    final int id = _nextId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    _sendPort.send(<Object?>[id, op, params]);
    return completer.future;
  }

  /// Stops the isolate; in-flight calls fail with a `StateError`.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final Completer<Object?> completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('the audio worker was closed'));
      }
    }
    _pending.clear();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _replies.close();
  }
}

/// Startup payload: where the worker sends replies and its readiness signal.
class _WorkerStart {
  const _WorkerStart(this.replies);

  final SendPort replies;
}

/// Worker entry point. Every engine call here may block; the isolate exists for that.
Future<void> _workerMain(_WorkerStart start) async {
  final ReceivePort inbox = ReceivePort();
  final LazerAudioAvailability availability = LazerAudioLoader.load();
  final LazerAudioApi? api = availability.api;
  if (api == null) {
    start.replies.send(<String>[
      'could not load the engine: ${availability.reason}',
    ]);
    inbox.close();
    return;
  }
  start.replies.send(inbox.sendPort);
  await for (final Object? message in inbox) {
    if (message is! List || message.length < 3) continue;
    final List<Object?> call = message.cast<Object?>();
    final int id = call[0] as int;
    final int op = call[1] as int;
    final List<Object?> params = (call[2] as List<Object?>?) ?? const <Object?>[];
    Object? value;
    String? error;
    try {
      value = _execute(api, op, params);
    } catch (failure, stack) {
      error = '$failure\n$stack';
    }
    start.replies.send(<Object?>[id, value, error]);
  }
}

/// Runs one command. Returns the value the caller's completer completes with.
Object? _execute(LazerAudioApi api, int op, List<Object?> params) {
  switch (op) {
    case LazerWorkerOp.create:
      return _create(api, params);
    case LazerWorkerOp.destroy:
      api.destroy(Pointer<Void>.fromAddress(params[0] as int));
      return null;
    case LazerWorkerOp.openFile:
      return _openFile(api, params);
    case LazerWorkerOp.openReader:
      return _openReader(api, params);
    case LazerWorkerOp.queueReader:
      return _queueReader(api, params);
    case LazerWorkerOp.clearQueuedReader:
      return api.clearQueuedReader(
        Pointer<Void>.fromAddress(params[0] as int),
        params[1] as int,
      );
    case LazerWorkerOp.stop:
      return api.stop(Pointer<Void>.fromAddress(params[0] as int));
    case LazerWorkerOp.setDevice:
      return _setDevice(api, params);
    case LazerWorkerOp.setVolume:
      return api.setVolume(
        Pointer<Void>.fromAddress(params[0] as int),
        (params[1] as num).toDouble(),
      );
    case LazerWorkerOp.setDsp:
      return _setDsp(api, params);
    default:
      throw StateError('unknown audio worker command $op');
  }
}

/// `[engineConfig fields..., event callback address, log callback address]`.
///
/// The callback addresses are `NativeCallable` function pointers created on the
/// UI isolate; the engine keeps them for its lifetime, so they must outlive it.
Object? _create(LazerAudioApi api, List<Object?> params) {
  final Pointer<LazerAudioEngineConfig> config =
      calloc<LazerAudioEngineConfig>();
  try {
    _writeDevice(config.ref.device, params.sublist(0, 6));
    config.ref
      ..abiVersion = lazerAudioAbiVersion
      ..structSize = sizeOf<LazerAudioEngineConfig>();
    config.ref.events.onEvent = Pointer<
      NativeFunction<LazerAudioEventNative>
    >.fromAddress(params[6] as int);
    config.ref.events.context = nullptr;
    config.ref.log.onLog = Pointer<
      NativeFunction<LazerAudioLogNative>
    >.fromAddress(params[7] as int);
    config.ref.log.context = nullptr;
    final Pointer<Void> engine = api.create(config);
    return engine == nullptr ? null : engine.address;
  } finally {
    calloc.free(config);
  }
}

/// `[engine, path, open params...]`.
Object? _openFile(LazerAudioApi api, List<Object?> params) {
  final Pointer<Utf8> path = (params[1] as String).toNativeUtf8();
  final Pointer<LazerAudioOpenParams> openParams = calloc<LazerAudioOpenParams>();
  try {
    _writeOpenParams(openParams, params.sublist(2));
    return api.openFileUtf8(
      Pointer<Void>.fromAddress(params[0] as int),
      path.cast<Uint8>(),
      openParams,
    );
  } finally {
    calloc.free(openParams);
    calloc.free(path);
  }
}

/// `[engine, reader address, open params...]`.
Object? _openReader(LazerAudioApi api, List<Object?> params) {
  final Pointer<LazerAudioOpenParams> openParams = calloc<LazerAudioOpenParams>();
  try {
    _writeOpenParams(openParams, params.sublist(2));
    return api.openReader(
      Pointer<Void>.fromAddress(params[0] as int),
      Pointer<LazerAudioReader>.fromAddress(params[1] as int),
      openParams,
    );
  } finally {
    calloc.free(openParams);
  }
}

/// `[engine, queue generation, reader address, open params...]`.
Object? _queueReader(LazerAudioApi api, List<Object?> params) {
  final Pointer<LazerAudioOpenParams> openParams = calloc<LazerAudioOpenParams>();
  try {
    _writeOpenParams(openParams, params.sublist(3));
    return api.queueReader(
      Pointer<Void>.fromAddress(params[0] as int),
      params[1] as int,
      Pointer<LazerAudioReader>.fromAddress(params[2] as int),
      openParams,
    );
  } finally {
    calloc.free(openParams);
  }
}

/// `[engine, device fields..., device token]`.
Object? _setDevice(LazerAudioApi api, List<Object?> params) {
  final Pointer<LazerAudioDeviceConfig> device =
      calloc<LazerAudioDeviceConfig>();
  try {
    _writeDevice(device.ref, params.sublist(1, 7));
    return api.setDevice(
      Pointer<Void>.fromAddress(params[0] as int),
      device,
    );
  } finally {
    calloc.free(device);
  }
}

/// `[engine, preampDb, limiterEnabled, limiterThresholdDb, bands, crossfeed]`,
/// where `crossfeed` is `[enabled, strength, algorithm, delayMs, cutoffHz]`.
Object? _setDsp(LazerAudioApi api, List<Object?> params) {
  final List<Object?> bands =
      (params[4] as List<Object?>?) ?? const <Object?>[];
  // The crossfeed block is append-only: a caller that predates it sends five
  // parameters, which must not be read as a missing sixth.
  final List<Object?> crossfeed = params.length > 5
      ? (params[5] as List<Object?>?) ?? const <Object?>[]
      : const <Object?>[];
  final Pointer<LazerAudioEqBand> bandArray = bands.isEmpty
      ? nullptr
      : calloc<LazerAudioEqBand>(bands.length);
  final Pointer<LazerAudioDspConfig> dsp = calloc<LazerAudioDspConfig>();
  try {
    for (int index = 0; index < bands.length; index++) {
      final List<Object?> band = bands[index] as List<Object?>;
      bandArray[index]
        ..kind = band[0] as int
        ..frequencyHz = (band[1] as num).toDouble()
        ..gainDb = (band[2] as num).toDouble()
        ..q = (band[3] as num).toDouble()
        ..enabled = band[4] as int;
    }
    dsp.ref
      ..preampDb = (params[1] as num).toDouble()
      ..bandCount = bands.length
      ..bands = bandArray
      ..limiterEnabled = (params[2] as int) != 0 ? 1 : 0
      ..limiterThresholdDb = (params[3] as num).toDouble()
      ..balanceChannels = 0;
    if (crossfeed.length >= 5) {
      dsp.ref
        ..crossfeedEnabled = (crossfeed[0] as int) != 0 ? 1 : 0
        ..crossfeedStrength = (crossfeed[1] as num).toDouble()
        ..crossfeedAlgorithm = crossfeed[2] as int
        ..crossfeedDelayMs = (crossfeed[3] as num).toDouble()
        ..crossfeedCutoffHz = (crossfeed[4] as num).toDouble();
    }
    return api.setDsp(Pointer<Void>.fromAddress(params[0] as int), dsp);
  } finally {
    calloc.free(dsp);
    if (bandArray != nullptr) calloc.free(bandArray);
  }
}

void _writeDevice(LazerAudioDeviceConfig device, List<Object?> values) {
  device
    ..deviceId = nullptr
    ..exclusive = values[0] as int
    ..resampleMode = values[1] as int
    ..targetSampleRate = values[2] as int
    ..bufferMillis = values[3] as int
    ..bitPerfect = values[4] as int
    ..dsdOutputMode = values[5] as int;
}

void _writeOpenParams(
  Pointer<LazerAudioOpenParams> params,
  List<Object?> values,
) {
  params.ref
    ..structSize = sizeOf<LazerAudioOpenParams>()
    ..startMillis = values[0] as int
    ..durationHintMillis = values[1] as int
    ..cueStartFrame75 = values[2] as int
    ..cueEndFrame75 = values[3] as int
    ..replayGainDb = (values[4] as num).toDouble();
}
