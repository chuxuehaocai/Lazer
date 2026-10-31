// The native engine behind the app's `AudioEngine` surface.
//
// This is the Flutter counterpart of the master branch's
// `DesktopNativeAudioPlayer`: FFmpeg decodes, the platform backend (WASAPI /
// ALSA / CoreAudio HAL) outputs, and the engine owns the clock, the gapless queue
// and the DSP chain. Only transport state crosses into Dart.
//
// Threading, which shapes everything here:
//   * calls that block (`create`, `open`, `queue`, `clear`, `stop`, `destroy`) go
//     through `LazerAudioWorker`, a dedicated isolate;
//   * `snapshot`/`stream_info`/`last_error` do not block and are called straight
//     from the UI isolate, so `position` stays synchronous;
//   * engine events arrive on engine threads through a `NativeCallable.listener`,
//     which is asynchronous — a terminal event is therefore confirmed against the
//     snapshot rather than trusted to arrive in order.
//
// Reader lifetime is the subtle part. The engine keeps a `LazerAudioReader` alive
// until it stops using it, so a reader may only be freed after a *serialised*
// worker call that guarantees the engine dropped it (a later
// `clear_queued_reader`, a finished `open`, or `stop`/`destroy`). Freeing on the
// Dart side alone would let the decoder read freed memory.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio_engine.dart';
import 'audio_path_log.dart';
import 'audio_stream_cache.dart';
import 'lazer_audio_abi.dart';
import 'lazer_audio_library.dart';
import 'lazer_audio_reader.dart';
import 'lazer_audio_worker.dart';
import 'lazer_stream_info.dart';

export 'lazer_stream_info.dart';

/// Native-engine implementation of the app's playback surface.
///
/// [create] returns null when this host has no usable engine binary, in which
/// case the app keeps `just_audio`; see `engine_factory.dart`.
class NativeAudioEngine
    implements
        AudioEngine,
        BufferedAudioEngine,
        BufferChangeReportingAudioEngine,
        SeekBoundaryReportingAudioEngine,
        QueueAudioEngine,
        FailureReportingAudioEngine,
        FocusAwareAudioEngine {
  NativeAudioEngine._(
    this._api,
    this._bridge,
    this._worker,
    this._events,
    this._cache,
    this._deviceSettings,
  );

  /// Loads the engine and creates a session.
  ///
  /// Returns null (logging why) when the native library is missing, its ABI
  /// version does not match, or the engine cannot be created on this device.
  /// [lastStartupFailure] then holds that reason, so `engine_factory.dart` can
  /// report a *session* failure instead of reusing the loader's (null) reason.
  static Future<NativeAudioEngine?> create({
    LazerDeviceSettings deviceSettings = const LazerDeviceSettings(),
    AudioStreamCache? cache,
  }) async {
    final LazerAudioAvailability availability = LazerAudioLoader.load();
    if (!availability.isAvailable) {
      lastStartupFailure = availability.reason;
      debugPrint('lazer-audio unavailable: ${availability.reason}');
      return null;
    }
    final LazerAudioApi api = availability.api!;
    LazerAudioWorker? worker;
    NativeCallable<LazerAudioEventNative>? events;
    AudioStreamCache? streamCache = cache;
    NativeAudioEngine? engine;
    try {
      worker = await LazerAudioWorker.spawn();
      // The callbacks need the instance they dispatch into; they cannot fire
      // before `lazer_audio_create` is called below.
      events = NativeCallable<LazerAudioEventNative>.listener((
        Pointer<Void> context,
        int event,
        int detail,
        int positionMillis,
      ) {
        engine?._handleEvent(event, detail, positionMillis);
      });
      streamCache ??= AudioStreamCache(getApplicationSupportDirectory);
      engine = NativeAudioEngine._(
        api,
        availability.bridge,
        worker,
        events,
        streamCache,
        deviceSettings,
      );
      final Object? address = await worker.call(LazerWorkerOp.create, <Object?>[
        ...deviceSettings.toDeviceMessage(),
        events.nativeFunction.address,
        // on_log's char* expires when the native callback returns. Dart
        // listeners are asynchronous, so pull owned log copies instead.
        0,
      ]);
      if (address == null) {
        throw StateError('lazer_audio_create returned no engine');
      }
      engine._engineAddress = address as int;
      if (api.readLog != null) {
        engine._logTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => engine?._drainLogs(),
        );
      }
      lastStartupFailure = null;
      return engine;
    } catch (error, stack) {
      lastStartupFailure = '$error';
      debugPrint('lazer-audio: engine startup failed: $error\n$stack');
      await engine?._shutdown();
      if (cache == null) streamCache?.close();
      if (engine == null) {
        events?.close();
        await worker?.close();
      }
      return null;
    }
  }

  /// Why the last [create] returned null, or null when it succeeded (or when the
  /// failure was the loader's, which already reports its own reason).
  static String? lastStartupFailure;

  final LazerAudioApi _api;
  final LazerAudioBridgeApi? _bridge;
  final LazerAudioWorker _worker;
  final NativeCallable<LazerAudioEventNative> _events;
  Timer? _logTimer;
  Pointer<Int32>? _logLevel;
  Pointer<Uint8>? _logBuffer;
  final AudioStreamCache _cache;
  LazerDeviceSettings _deviceSettings;
  int _engineAddress = 0;

  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<void> _bufferChanges =
      StreamController<void>.broadcast();
  final StreamController<int> _advanced = StreamController<int>.broadcast();
  final StreamController<String> _failures =
      StreamController<String>.broadcast();
  final StreamController<LazerStreamInfo?> _streamInfos =
      StreamController<LazerStreamInfo?>.broadcast();

  /// Serialises source mutations so a prefetch never lands in a replaced queue.
  Future<void> _operations = Future<void>.value();

  int _generation = 0;
  int _transportRequest = 0;
  int _queueId = 0;
  int _queueGeneration = 0;
  int _queueIndex = 0;
  List<String> _pendingUrls = <String>[];
  bool _sourceLoaded = false;
  bool _disposed = false;
  bool _shutdownStarted = false;
  bool _completionSent = false;
  double _volume = 1;

  AudioStreamEntry? _activeEntry;
  NativeStreamReader? _activeReader;
  AudioStreamEntry? _queuedEntry;
  NativeStreamReader? _queuedReader;
  String? _queuedUrl;
  LazerStreamInfo? _streamInfo;
  Duration _position = Duration.zero;
  Duration? _duration;
  Duration? _pendingSeek;

  /// When [_pendingSeek] was issued, so a `SeekCompleted` event that never
  /// arrives (a seek while paused, or a dropped callback) cannot pin the reported
  /// position forever.
  int _pendingSeekAtMicros = 0;

  /// Successor preparations still inside the worker, drained before `destroy`:
  /// destroying the engine while `queue_reader` is running would free memory the
  /// call is still using.
  int _preparationsInFlight = 0;
  final List<Completer<void>> _preparationsIdle = <Completer<void>>[];

  Pointer<LazerAudioSnapshot>? _snapshotBuffer;
  Pointer<LazerAudioStreamInfo>? _streamInfoBuffer;

  /// The initialized output session of the current source, or null when idle.
  LazerStreamInfo? get streamInfo => _streamInfo;

  /// Emits the negotiated format whenever a source is opened or closed.
  Stream<LazerStreamInfo?> get streamInfoStream => _streamInfos.stream;

  /// Whether network sources can be played: that needs the reader bridge.
  bool get supportsStreaming => _bridge != null;

  /// The format facts FFmpeg was built with, for the diagnostics panel.
  String get buildInformation => _api.buildInformation();

  /// Installed by `PlaybackSession`; see [FocusAwareAudioEngine].
  @override
  Future<bool> Function()? activateSession;

  @override
  Stream<String> get failures => _failures.stream;

  /// Always null: a native session that failed to start never becomes this
  /// object, so its reason travels with the fallback engine instead
  /// (`JustAudioEngine.pendingFailure`).
  @override
  String? get pendingFailure => null;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<void> get bufferChanges => _bufferChanges.stream;

  @override
  Stream<int> get indexStream => _advanced.stream;

  @override
  bool get active => _sourceLoaded;

  @override
  Duration get position {
    final Duration? pending = _pendingSeek;
    if (pending != null) {
      final Duration age = Duration(
        microseconds:
            DateTime.now().microsecondsSinceEpoch - _pendingSeekAtMicros,
      );
      if (age < const Duration(seconds: 2)) return pending;
      _pendingSeek = null;
    }
    final int? address = _engineAddressOrNull;
    if (address == null) return _position;
    final Pointer<LazerAudioSnapshot> snapshot = _snapshotBuffer ??=
        calloc<LazerAudioSnapshot>();
    if (_api.snapshot(Pointer<Void>.fromAddress(address), snapshot) !=
        lazerAudioOk) {
      return _position;
    }
    final int millis = snapshot.ref.positionMillis;
    if (millis >= 0) _position = Duration(milliseconds: millis);
    final int total = snapshot.ref.durationMillis;
    if (total > 0) _duration = Duration(milliseconds: total);
    return _position;
  }

  @override
  Duration? get duration => _duration;

  @override
  bool get seekIsLimitedByBuffer => _activeEntry?.complete == false;

  @override
  Duration get bufferedPosition {
    final AudioStreamEntry? entry = _activeEntry;
    final Duration? total = _duration;
    if (entry == null) return total ?? _position;
    if (total == null || total == Duration.zero) {
      return _position;
    }
    final Duration buffered = total * entry.progress;
    return buffered > _position ? buffered : _position;
  }

  int? get _engineAddressOrNull => _engineAddress == 0 ? null : _engineAddress;

  /// Re-reads the negotiated format; also refreshes [streamInfo].
  LazerStreamInfo? readStreamInfo() {
    final int? address = _engineAddressOrNull;
    if (address == null) return _streamInfo;
    final Pointer<LazerAudioStreamInfo> info = _streamInfoBuffer ??=
        calloc<LazerAudioStreamInfo>();
    if (_api.streamInfo(Pointer<Void>.fromAddress(address), info) !=
        lazerAudioOk) {
      return _streamInfo;
    }
    final LazerStreamInfo parsed = LazerStreamInfo.fromNative(info.ref);
    _streamInfo = parsed;
    return parsed;
  }

  String lastError() {
    final int? address = _engineAddressOrNull;
    if (address == null) return 'engine not initialized';
    return _api.lastError(Pointer<Void>.fromAddress(address));
  }

  @override
  Future<void> setUrl(String url) {
    final int generation = ++_generation;
    _sourceLoaded = false;
    _completionSent = false;
    _pendingUrls = <String>[];
    return _serialize(() async {
      await _clearQueued();
      if (generation != _generation) return;
      await _openSource(url, generation);
    });
  }

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    final int queueId = ++_queueId;
    final int generation = ++_generation;
    _sourceLoaded = false;
    _completionSent = false;
    if (urls.isEmpty) {
      _pendingUrls = <String>[];
      return queueId;
    }
    final int index = startIndex.clamp(0, urls.length - 1);
    _queueIndex = index;
    _pendingUrls = urls.sublist(index + 1);
    await _serialize(() async {
      await _clearQueued();
      if (generation != _generation) return;
      await _openSource(urls[index], generation);
    });
    return queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async {
    if (queueId != _queueId || !_sourceLoaded || _bridge == null) return false;
    _pendingUrls = <String>[url];
    // Deliberately not part of the `_operations` chain: preparing the successor
    // reads its first bytes, and a skip pressed meanwhile must not wait for that.
    // A preparation that loses the race releases its own reader (see
    // `_prepareSuccessor`), so nothing leaks.
    unawaited(_prepareSuccessor(url));
    return true;
  }

  @override
  Future<bool> playQueuedNext() async {
    final String? next = _queuedUrl ?? _pendingUrls.firstOrNull;
    if (next == null) return false;
    final int generation = ++_generation;
    return _serialize(() async {
      await _clearQueued();
      if (generation != _generation) return false;
      _queueIndex++;
      await _openSource(next, generation);
      return generation == _generation;
    });
  }

  @override
  Future<void> play() async {
    final int generation = _generation;
    final int request = ++_transportRequest;
    final int? address = _engineAddressOrNull;
    if (address == null || !_sourceLoaded) return;
    // Focus first: starting the device before the session is active is what makes
    // the first second of a track play into a ducked or interrupted stream.
    final Future<bool> Function()? focus = activateSession;
    if (focus != null && !await focus()) {
      throw StateError('Audio session activation denied');
    }
    if (!_sourceLoaded ||
        _disposed ||
        generation != _generation ||
        request != _transportRequest) {
      return;
    }
    final int status = _status(
      await _worker.call(LazerWorkerOp.play, [address]),
    );
    if (status != lazerAudioOk) {
      throw StateError('lazer-audio: play failed ($status): ${lastError()}');
    }
  }

  @override
  Future<void> pause() async {
    ++_transportRequest;
    final int? address = _engineAddressOrNull;
    if (address == null) return;
    await _worker.call(LazerWorkerOp.pause, [address]);
  }

  @override
  Future<void> seek(Duration position) async {
    final int generation = _generation;
    final int? address = _engineAddressOrNull;
    if (address == null || position < Duration.zero) return;
    final int status = _status(
      await _worker.call(LazerWorkerOp.seek, [
        address,
        position.inMilliseconds,
      ]),
    );
    if (status != lazerAudioOk || generation != _generation || _disposed) {
      return;
    }
    _position = position;
    // The engine's published position only moves once the decode side applied
    // the seek; reporting the target meanwhile keeps the rail from jumping back.
    _pendingSeek = position;
    _pendingSeekAtMicros = DateTime.now().microsecondsSinceEpoch;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    final int? address = _engineAddressOrNull;
    if (address == null) return;
    await _worker.call(LazerWorkerOp.setVolume, <Object?>[address, _volume]);
  }

  /// Replaces the output settings for the next opened source.
  ///
  /// Exclusive mode, bit-perfect streaming and DSD policy are negotiated when a
  /// stream opens, so this takes effect on the next track; the engine has no way
  /// to renegotiate a running stream.
  Future<void> setDeviceSettings(LazerDeviceSettings settings) async {
    _deviceSettings = settings;
    final int? address = _engineAddressOrNull;
    if (address == null) return;
    await _worker.call(LazerWorkerOp.setDevice, <Object?>[
      address,
      ...settings.toDeviceMessage(),
      settings.deviceToken,
    ]);
  }

  /// Applies the EQ/limiter chain.
  ///
  /// A non-zero ReplayGain is per-source (`LazerOpenSettings.replayGainDb`) and the
  /// engine rejects it while bit-perfect or DoP is active, rather than silently
  /// dropping the processing the user asked for.
  Future<void> setEqualizer({
    double preampDb = 0,
    bool limiterEnabled = false,
    double limiterThresholdDb = -1,
    List<LazerEqBandSettings> bands = const <LazerEqBandSettings>[],
    LazerCrossfeedSettings crossfeed = const LazerCrossfeedSettings(),
  }) async {
    final int? address = _engineAddressOrNull;
    if (address == null) return;
    await _worker.call(LazerWorkerOp.setDsp, <Object?>[
      address,
      preampDb,
      limiterEnabled ? 1 : 0,
      limiterThresholdDb,
      <Object?>[for (final LazerEqBandSettings band in bands) band.toMessage()],
      crossfeed.toMessage(),
    ]);
  }

  /// Deletes the audio cache; playback stops because its files are gone.
  Future<int> clearCache() async {
    await stop();
    return _cache.clear();
  }

  @override
  Future<void> stop() async {
    ++_generation;
    _sourceLoaded = false;
    _completionSent = false;
    _pendingUrls = <String>[];
    _position = Duration.zero;
    _pendingSeek = null;
    _duration = null;
    final int? address = _engineAddressOrNull;
    if (address != null) {
      try {
        // Serialised: after this returns the engine no longer reads any source,
        // so the readers and cache entries can be dropped.
        await _worker.call(LazerWorkerOp.stop, <Object?>[address]);
      } catch (error) {
        debugPrint('lazer-audio: stop failed: $error');
      }
    }
    await _clearQueued();
    _releaseActive();
    _publishStreamInfo(null);
  }

  @override
  void dispose() {
    unawaited(_shutdown());
  }

  Future<void> _shutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    _logTimer?.cancel();
    _drainLogs();
    _disposed = true;
    ++_generation;
    _sourceLoaded = false;
    final int? address = _engineAddressOrNull;
    // Let the mutation chain and any successor preparation finish (bounded, so a
    // download that never delivers cannot hang shutdown) before the engine is
    // destroyed.
    await _serialize(
      () async {},
    ).timeout(const Duration(seconds: 5), onTimeout: () {});
    await _awaitPreparations();
    _engineAddress = 0;
    try {
      if (address != null) {
        await _worker.call(LazerWorkerOp.stop, <Object?>[address]);
        await _worker.call(LazerWorkerOp.destroy, <Object?>[address]);
      }
    } catch (error) {
      debugPrint('lazer-audio: shutdown failed: $error');
    }
    // Readers are only freed once the engine has joined its threads.
    _releaseActive();
    _queuedReader?.release();
    _queuedReader = null;
    _queuedEntry?.cancel();
    _queuedEntry = null;
    await _worker.close();
    _events.close();
    if (_logLevel != null) calloc.free(_logLevel!);
    if (_logBuffer != null) calloc.free(_logBuffer!);
    _logLevel = null;
    _logBuffer = null;
    if (_snapshotBuffer != null) calloc.free(_snapshotBuffer!);
    _snapshotBuffer = null;
    if (_streamInfoBuffer != null) calloc.free(_streamInfoBuffer!);
    _streamInfoBuffer = null;
    await _completed.close();
    await _bufferChanges.close();
    await _advanced.close();
    await _failures.close();
    await _streamInfos.close();
    _cache.close();
  }

  /// Waits for in-flight successor preparations, up to a bounded time.
  Future<void> _awaitPreparations() async {
    if (_preparationsInFlight == 0) return;
    final Completer<void> idle = Completer<void>();
    _preparationsIdle.add(idle);
    await idle.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final Future<T> result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Opens [url] as the audible source; [generation] rejects superseded opens.
  Future<void> _openSource(String url, int generation) async {
    if (generation != _generation || _disposed) return;
    final AudioStreamEntry? entry = await _cacheEntryFor(url);
    if (generation != _generation || _disposed) return;
    NativeStreamReader? reader;
    try {
      final int? address = _engineAddressOrNull;
      if (address == null) return;
      if (entry != null) {
        final LazerAudioBridgeApi? bridge = _bridge;
        if (bridge == null) {
          throw StateError(
            'the lazer-audio reader bridge is missing, so network sources '
            'cannot be opened',
          );
        }
        reader = NativeStreamReader.create(
          bridge,
          path: entry.file.path,
          expectedBytes: entry.expectedBytes,
        );
        if (reader == null) {
          throw StateError('the reader bridge rejected ${entry.file.path}');
        }
        final NativeStreamReader sourceReader = reader;
        final AudioStreamEntry sourceEntry = entry;
        entry
          ..onAppended = () {
            sourceReader.notifyAppended();
            if (identical(_activeEntry, sourceEntry)) _emitBufferChange();
          }
          ..onFinished = (bool failed) {
            sourceReader.finish(failed: failed);
            if (identical(_activeEntry, sourceEntry)) _emitBufferChange();
          };
      }

      final int status = await _openWithDsdPolicy(
        address: address,
        path: entry == null ? _localPath(url) : null,
        reader: reader,
        generation: generation,
      );
      if (status != lazerAudioOk) {
        reader?.release();
        throw StateError(
          'lazer-audio could not open $url ($status): ${lastError()}',
        );
      }
      // The engine just accepted this source, so whatever was active before is
      // gone and its reader can be freed now.
      _releaseActive();
      _activeEntry = entry;
      _activeReader = reader;
      _emitBufferChange();
      _sourceLoaded = true;
      if (generation != _generation) {
        // A newer request arrived while this one was opening. It is queued behind
        // this call on the worker, so the engine still holds *this* source until
        // that request runs — the reader must stay alive and is therefore adopted
        // here. The queued request (or the next stop/dispose) releases it. Freeing
        // it now would let the decode thread read freed memory.
        return;
      }
      _completionSent = false;
      _position = Duration.zero;
      _pendingSeek = null;
      _duration = null;
      _publishStreamInfo(readStreamInfo());
    } catch (error) {
      reader?.release();
      entry?.cancel();
      if (generation == _generation) _sourceLoaded = false;
      rethrow;
    }
  }

  /// Opens the source, walking the DSD policy chain if the device refuses the first.
  ///
  /// The engine accepts one explicit DSD policy per open and refuses rather than
  /// downgrading, so "auto" is resolved here: Native, then DoP, then PCM, each attempt
  /// re-opening the same source under the next policy. Only transport refusals are
  /// retried — a missing file or a decode error would fail identically everywhere.
  Future<int> _openWithDsdPolicy({
    required int address,
    required String? path,
    required NativeStreamReader? reader,
    required int generation,
  }) async {
    final List<int> attempts = _deviceSettings.dsdAttempts;
    int status = lazerAudioErrorState;
    for (int index = 0; index < attempts.length; index++) {
      if (generation != _generation || _disposed) return lazerAudioErrorState;
      await _applyOutputSettings(address, dsdOverride: attempts[index]);
      status = await _openOnce(address, path, reader);
      if (status == lazerAudioOk) {
        if (index > 0) {
          debugPrint(
            'lazer-audio: DSD auto settled on policy ${attempts[index]} after '
            '${index + 1} attempts',
          );
        }
        return status;
      }
      if (status != lazerAudioErrorUnsupported &&
          status != lazerAudioErrorDevice) {
        return status;
      }
    }
    return status;
  }

  Future<int> _openOnce(
    int address,
    String? path,
    NativeStreamReader? reader,
  ) async {
    if (path != null) {
      return _status(
        await _worker.call(LazerWorkerOp.openFile, <Object?>[
          address,
          path,
          ...const LazerOpenSettings().toMessage(),
        ]),
      );
    }
    return _status(
      await _worker.call(LazerWorkerOp.openReader, <Object?>[
        address,
        reader!.address,
        ...const LazerOpenSettings().toMessage(),
      ]),
    );
  }

  /// Applies the output policy; [dsdOverride] replaces the DSD field for one
  /// attempt of the auto chain.
  Future<void> _applyOutputSettings(int address, {int? dsdOverride}) async {
    final List<Object?> message = _deviceSettings.toDeviceMessage();
    if (dsdOverride != null) message[5] = dsdOverride;
    await _worker.call(LazerWorkerOp.setDevice, <Object?>[
      address,
      ...message,
      _deviceSettings.deviceToken,
    ]);
    await _worker.call(LazerWorkerOp.setVolume, <Object?>[address, _volume]);
  }

  /// Prepares [url] as the successor inside the running output session.
  ///
  /// Detached from the mutation chain on purpose: `queue_reader` decodes the
  /// successor, which waits for its bytes. Whoever loses the race — because the
  /// queue was replaced, the source stopped, or the app moved on — frees its own
  /// reader only after a later serialised call has made the engine drop it.
  Future<void> _prepareSuccessor(String url) async {
    final LazerAudioBridgeApi? bridge = _bridge;
    final int? address = _engineAddressOrNull;
    if (bridge == null || address == null || !_sourceLoaded || _disposed) {
      return;
    }
    final int generation = ++_queueGeneration;
    _preparationsInFlight++;
    AudioStreamEntry? entry;
    NativeStreamReader? reader;
    try {
      entry = await _cacheEntryFor(url);
      if (entry == null) return;
      reader = NativeStreamReader.create(
        bridge,
        path: entry.file.path,
        expectedBytes: entry.expectedBytes,
      );
      if (reader == null) return;
      // The cache download can finish after this local is transferred to
      // `_queuedReader` and set to null below. Capture the reader itself so the
      // completion callback still signals the bridge instead of throwing from
      // the cache's unawaited download future.
      final NativeStreamReader queuedReader = reader;
      final AudioStreamEntry queuedEntry = entry;
      entry
        ..onAppended = () {
          queuedReader.notifyAppended();
          if (identical(_activeEntry, queuedEntry)) _emitBufferChange();
        }
        ..onFinished = (bool failed) {
          queuedReader.finish(failed: failed);
          if (identical(_activeEntry, queuedEntry)) _emitBufferChange();
        };
      final int status = _status(
        await _worker.call(LazerWorkerOp.queueReader, <Object?>[
          address,
          generation,
          reader.address,
          ...const LazerOpenSettings().toMessage(),
        ]),
      );
      if (status != lazerAudioOk ||
          generation != _queueGeneration ||
          !_sourceLoaded ||
          _disposed) {
        await _settleSupersededReader(address, reader, entry);
        reader = null;
        entry = null;
        return;
      }
      _queuedReader?.release();
      _queuedEntry?.cancel();
      _queuedReader = reader;
      _queuedEntry = entry;
      _queuedUrl = url;
      reader = null;
      entry = null;
    } catch (error) {
      debugPrint('lazer-audio: preparing $url failed: $error');
      if (reader != null) {
        await _settleSupersededReader(address, reader, entry);
      }
    } finally {
      _preparationsInFlight--;
      if (_preparationsInFlight == 0) {
        for (final Completer<void> idle in _preparationsIdle) {
          if (!idle.isCompleted) idle.complete();
        }
        _preparationsIdle.clear();
      }
    }
  }

  /// Resolves a successor preparation that lost its race.
  ///
  /// The engine may still be reading [reader], so the only safe way to free it is
  /// a *serialised* `clear_queued_reader`: it runs on the same worker isolate as
  /// the `queue_reader` that installed the successor, so when it returns the
  /// engine has either dropped the successor (`Ok`) or promoted it across the
  /// audible boundary (`QueueAlreadyActive`). In the second case the reader is the
  /// active source now, so it is adopted here and the track change is reported —
  /// the asynchronous `TrackChanged` event may already have been delivered (and
  /// found nothing queued) or may arrive later and find nothing either.
  Future<void> _settleSupersededReader(
    int address,
    NativeStreamReader reader,
    AudioStreamEntry? entry,
  ) async {
    final int generation = ++_queueGeneration;
    int result = lazerAudioErrorState;
    try {
      result = _status(
        await _worker.call(LazerWorkerOp.clearQueuedReader, <Object?>[
          address,
          generation,
        ]),
      );
    } catch (error) {
      debugPrint('lazer-audio: clearing a superseded reader failed: $error');
    }
    if (result == lazerAudioQueueAlreadyActive && !_disposed) {
      _activeReader?.release();
      _activeEntry?.cancel();
      _activeReader = reader;
      _activeEntry = entry;
      _queuedReader = null;
      _queuedEntry = null;
      _queuedUrl = null;
      _sourceLoaded = true;
      _completionSent = false;
      _queueIndex++;
      _emitBufferChange();
      _publishStreamInfo(readStreamInfo());
      if (!_advanced.isClosed) _advanced.add(_queueIndex);
      return;
    }
    reader.release();
    entry?.cancel();
  }

  /// Drops the prepared successor and its cache entry.
  Future<void> _clearQueued() async {
    final int? address = _engineAddressOrNull;
    final int hadQueued = _queuedReader == null ? 0 : 1;
    final int generation = ++_queueGeneration;
    if (address != null && hadQueued == 1) {
      try {
        await _worker.call(LazerWorkerOp.clearQueuedReader, <Object?>[
          address,
          generation,
        ]);
      } catch (error) {
        debugPrint('lazer-audio: clearing the queued source failed: $error');
      }
    }
    _queuedUrl = null;
    _queuedReader?.release();
    _queuedReader = null;
    _queuedEntry?.cancel();
    _queuedEntry = null;
  }

  /// Resolves the cache entry for [url], or null for a local file.
  Future<AudioStreamEntry?> _cacheEntryFor(String url) async {
    final Uri? uri = Uri.tryParse(url);
    final String scheme = uri?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      return _cache.open(url);
    }
    return null;
  }

  String _localPath(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    return url;
  }

  void _releaseActive() {
    _activeReader?.release();
    _activeReader = null;
    _activeEntry?.cancel();
    _activeEntry = null;
    _emitBufferChange();
  }

  void _emitBufferChange() {
    if (!_bufferChanges.isClosed) _bufferChanges.add(null);
  }

  void _publishStreamInfo(LazerStreamInfo? info) {
    _streamInfo = info;
    if (!_streamInfos.isClosed) _streamInfos.add(info);
    // The negotiation record: what the endpoint accepted, not what was asked
    // for. One line per open / gapless hand-off / DSD policy retry.
    logAudioPathEvent('format', <String, Object?>{
      'codec': info?.codec,
      'source': info == null
          ? null
          : info.hasDsdSource
          ? 'DSD${info.sourceDsdRateMultiplier}x'
          : '${info.sourceSampleRate}/${info.sourceBitsPerSample}/${info.sourceChannels}',
      'output': info == null
          ? null
          : '${info.outputSampleRate}/${info.outputBitsPerSample}/${info.outputChannels}',
      'container_bits': info?.outputContainerBitsPerSample,
      'float': info == null ? null : (info.outputIsFloat ? 1 : 0),
      'exclusive': info == null ? null : (info.outputExclusive ? 1 : 0),
      'selection': info?.outputFormatSelection,
      'bit_perfect': info == null ? null : (info.bitPerfectActive ? 1 : 0),
      'requested_bit_perfect': _deviceSettings.bitPerfect ? 1 : 0,
      'requested_exclusive': _deviceSettings.exclusive ? 1 : 0,
    });
  }

  void _drainLogs() {
    final read = _api.readLog;
    final address = _engineAddressOrNull;
    if (read == null || address == null) return;
    final level = _logLevel ??= calloc<Int32>();
    final buffer = _logBuffer ??= calloc<Uint8>(2048);
    for (var i = 0; i < 32; i++) {
      final count = read(
        Pointer<Void>.fromAddress(address),
        level,
        buffer,
        2048,
      );
      if (count <= 0) break;
      debugPrint('lazer-audio: ${lazerReadCString(buffer, maxBytes: count)}');
    }
  }

  void _handleEvent(int event, int detail, int positionMillis) {
    if (_disposed || !_sourceLoaded) return;
    switch (event) {
      case lazerAudioEventEnded:
        _finishSource();
      case lazerAudioEventTrackChanged:
        _crossIntoSuccessor(positionMillis);
      case lazerAudioEventFailed:
        _reportFailure('playback failed (${_errorName(detail)})');
      case lazerAudioEventDeviceLost:
        _reportFailure('the output device was lost');
      case lazerAudioEventSeekCompleted:
        _pendingSeek = null;
        _position = Duration(milliseconds: positionMillis);
      default:
        // Ready and BufferProgress carry nothing the app does not read from the
        // clock and the cache.
        break;
    }
  }

  void _finishSource() {
    if (_completionSent) return;
    _completionSent = true;
    _pendingSeek = null;
    final Duration? total = _duration;
    if (total != null) _position = total;
    if (!_completed.isClosed) _completed.add(null);
  }

  void _reportFailure(String message) {
    if (_completionSent) return;
    _completionSent = true;
    if (!_failures.isClosed) _failures.add(message);
  }

  /// The engine crossed into the queued successor inside the same output session.
  void _crossIntoSuccessor(int positionMillis) {
    final NativeStreamReader? successor = _queuedReader;
    if (successor == null) {
      // The boundary was crossed for a successor this isolate did not track (the
      // preparation lost its race and `_settleSupersededReader` already reported
      // it, or the event arrived after a stop). Nothing to swap; the current
      // reader stays owned by `_activeReader`.
      return;
    }
    final NativeStreamReader? previousReader = _activeReader;
    final AudioStreamEntry? previousEntry = _activeEntry;
    _activeReader = successor;
    _activeEntry = _queuedEntry;
    _queuedReader = null;
    _queuedEntry = null;
    _queuedUrl = null;
    _queueIndex++;
    _position = Duration(milliseconds: positionMillis);
    _pendingSeek = null;
    _completionSent = false;
    _sourceLoaded = true;
    previousReader?.release();
    previousEntry?.cancel();
    _emitBufferChange();
    _publishStreamInfo(readStreamInfo());
    if (!_advanced.isClosed) _advanced.add(_queueIndex);
    // A multi-URL queue can already hold the following track; the app otherwise
    // appends one in reaction to this event.
    final String? next = _pendingUrls.firstOrNull;
    if (next != null) {
      _pendingUrls = _pendingUrls.skip(1).toList();
      unawaited(_prepareSuccessor(next));
    }
  }

  String _errorName(int code) => switch (code) {
    lazerAudioErrorInvalidArgument => 'invalid argument',
    lazerAudioErrorUnsupported => 'unsupported',
    lazerAudioErrorNoMemory => 'out of memory',
    lazerAudioErrorSource => 'source error',
    lazerAudioErrorDecode => 'decode error',
    lazerAudioErrorDevice => 'device error',
    lazerAudioErrorCancelled => 'cancelled',
    lazerAudioErrorState => 'invalid state',
    _ => 'code $code',
  };

  int _status(Object? value) => value is int ? value : lazerAudioErrorState;
}
