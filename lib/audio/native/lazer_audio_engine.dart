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
//   * reader cancellation wakes blocked reads outside that worker, without
//     freeing the callbacks the engine still owns;
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

import '../audio_operation_queue.dart';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import '../../storage/app_storage.dart';
import '../../diagnostics/app_log.dart';

import '../audio_engine.dart';
import '../android_usb_audio.dart';
import 'audio_path_log.dart';
import 'audio_stream_cache.dart';
import 'engine_metrics.dart';
import 'lazer_audio_abi.dart';
import 'lazer_audio_library.dart';
import 'lazer_audio_reader.dart';
import 'lazer_audio_worker.dart';
import 'native_engine_ownership.dart';
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
        StartupBufferReportingAudioEngine,
        BufferChangeReportingAudioEngine,
        SeekBoundaryReportingAudioEngine,
        SeekRangeReportingAudioEngine,
        QueuedSourceReportingAudioEngine,
        MixPresentingAudioEngine,
        SerialQueueAudioEngine,
        AutoMixConfigurableAudioEngine,
        FailureReportingAudioEngine,
        FocusAwareAudioEngine,
        SessionPreparingAudioEngine,
        // AAudio's endpoint is held by this engine, so an interruption has to
        // close the device instead of parking a stream the platform will take.
        InterruptionYieldingAudioEngine,
        StreamingBufferHealthAudioEngine,
        VolumeConstraintAudioEngine {
  NativeAudioEngine._(
    this._api,
    this._bridge,
    this._worker,
    this._events,
    this._cache,
    this._deviceSettings, [
    NativeEngineOwnershipBudget? ownershipBudget,
    Object? reservation,
  ]) : _ownershipBudget = ownershipBudget ?? _sharedOwnershipBudget {
    _ownershipBudget.claim(this, reservation: reservation);
  }

  static final _sharedOwnershipBudget = NativeEngineOwnershipBudget();
  final NativeEngineOwnershipBudget _ownershipBudget;

  @visibleForTesting
  factory NativeAudioEngine.forTesting({
    required LazerAudioApi api,
    required LazerAudioBridgeApi bridge,
    required LazerAudioWorker worker,
    required AudioStreamCache cache,
    NativeEngineOwnershipBudget? ownershipBudget,
  }) {
    final budget = ownershipBudget ?? NativeEngineOwnershipBudget();
    if (budget.blocked || budget.busy) {
      throw StateError('native ownership is unavailable');
    }
    void ignoreEvent(
      Pointer<Void> context,
      int event,
      int detail,
      int positionMillis,
    ) {}
    return NativeAudioEngine._(
      api,
      bridge,
      worker,
      NativeCallable<LazerAudioEventNative>.listener(ignoreEvent),
      cache,
      const LazerDeviceSettings(),
      budget,
    ).._engineAddress = 1;
  }

  @visibleForTesting
  void deliverEventForTesting(int event) => _handleEvent(event, 0, 0);

  @visibleForTesting
  Future<void> prepareSuccessorForTesting(String url) => _prepareSuccessor(url);

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
    if (_sharedOwnershipBudget.blocked || _sharedOwnershipBudget.busy) {
      lastStartupFailure = _sharedOwnershipBudget.blocked
          ? 'Native audio cleanup could not be confirmed; restart the app.'
          : 'Native audio already has an active owner.';
      return null;
    }
    return _sharedOwnershipBudget.admit(
      (reservation) => _createReserved(
        reservation,
        deviceSettings: deviceSettings,
        cache: cache,
      ),
    );
  }

  static Future<NativeAudioEngine?> _createReserved(
    Object reservation, {
    required LazerDeviceSettings deviceSettings,
    required AudioStreamCache? cache,
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
      streamCache ??= AudioStreamCache(appSupportDirectory);
      engine = NativeAudioEngine._(
        api,
        availability.bridge,
        worker,
        events,
        streamCache,
        deviceSettings,
        _sharedOwnershipBudget,
        reservation,
      );
      engine._creationInDoubt = true;
      final Object? address = await worker.call(LazerWorkerOp.create, <Object?>[
        ...deviceSettings.toDeviceMessage(),
        events.nativeFunction.address,
        // on_log's char* expires when the native callback returns. Dart
        // listeners are asynchronous, so pull owned log copies instead.
        0,
        deviceSettings.deviceToken,
      ]);
      engine._creationInDoubt = false;
      if (address == null) {
        throw StateError('lazer_audio_create returned no engine');
      }
      engine._engineAddress = address as int;
      final created = engine;
      unawaited(
        worker.exited.then((_) {
          if (!created._shutdownStarted) created._faultWorker();
        }),
      );
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
  StreamSubscription<String>? _usbDetachSubscription;
  bool _usbConnectionsOpened = false;
  bool _nativeDestroyed = false;
  bool _creationInDoubt = false;
  bool _destroyRequested = false;
  bool _ownershipFaulted = false;
  String? _workerFailure;
  Future<void>? _shutdownFuture;
  final Set<NativeStreamReader> _unconfirmedReaders = {};
  static const _teardownTimeout = Duration(seconds: 5);
  int _engineAddress = 0;

  String? get workerFailure => _workerFailure;
  @visibleForTesting
  Future<void> get shutdownSettled => _shutdownFuture ?? Future<void>.value();

  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<void> _bufferChanges =
      StreamController<void>.broadcast();
  final StreamController<int> _advanced = StreamController<int>.broadcast();
  final StreamController<AudioFailure> _failures =
      StreamController<AudioFailure>.broadcast();
  final StreamController<LazerStreamInfo?> _streamInfos =
      StreamController<LazerStreamInfo?>.broadcast();

  /// Serialises source mutations so a prefetch never lands in a replaced queue.
  final AudioOperationQueue _operationQueue = AudioOperationQueue();
  Future<void> get _operations => _operationQueue.idle;
  final AudioOperationQueue _preparationQueue = AudioOperationQueue(
    maximumPending: 2,
  );

  int _generation = 0;
  int _transportRequest = 0;
  int _queueId = 0;
  int _queueGeneration = 0;
  int _successorRequestGeneration = 0;
  int _confirmedSourceGeneration = 0;
  int _queueIndex = 0;
  List<String> _pendingUrls = <String>[];
  bool _sourceLoaded = false;
  bool _disposed = false;
  bool _mixPresented = false;
  int _mixStartOutgoingMillis = 0;
  bool _shutdownStarted = false;
  bool _completionSent = false;
  double _volume = 1;
  List<Object?>? _pendingDspSettings;
  bool get hasPendingDspSettings => _pendingDspSettings != null;

  AudioStreamEntry? _activeEntry;
  NativeStreamReader? _activeReader;
  NativeStreamReader? _openingReader;
  final Set<NativeStreamReader> _preparingReaders = {};

  /// The successor the engine currently holds, bound to the generations that
  /// produced it. Keeping the reader, its cache entry, the URL and both
  /// generations in one immutable record means a clear can only ever name the
  /// exact target this isolate prepared, instead of a set of fields that could
  /// drift apart.
  _SuccessorBinding? _queued;
  final List<_SuccessorBinding> _deferredReaderRetirements = [];
  LazerStreamInfo? _streamInfo;
  Duration _position = Duration.zero;
  Duration? _duration;
  Duration? _pendingSeek;

  /// When [_pendingSeek] was issued, so a `SeekCompleted` event that never
  /// arrives (a seek while paused, or a dropped callback) cannot pin the reported
  /// position forever. See [seekHoldCeiling].
  int _pendingSeekAtMicros = 0;

  /// Successor preparations still inside the worker, drained before `destroy`:
  /// destroying the engine while `queue_reader` is running would free memory the
  /// call is still using.
  int _preparationsInFlight = 0;
  final List<Completer<void>> _preparationsIdle = <Completer<void>>[];

  Pointer<LazerAudioSnapshot>? _snapshotBuffer;
  Pointer<LazerAudioStreamInfo>? _streamInfoBuffer;

  /// The initialized output session of the current source, or null when idle.
  LazerStreamInfo? get streamInfo => _sourceLoaded ? _streamInfo : null;

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
  Future<void> Function()? prepareSession;

  @override
  Stream<AudioFailure> get failures => _failures.stream;

  /// Always null: a native session that failed to start never becomes this
  /// object, so its reason travels with the fallback engine instead
  /// (`JustAudioEngine.pendingFailure`).
  @override
  AudioFailure? get pendingFailure => null;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<void> get bufferChanges => _bufferChanges.stream;

  @override
  Stream<int> get indexStream => _advanced.stream;

  @override
  bool get active => _sourceLoaded;

  @override
  Duration get position => _readPosition();

  Duration _readPosition() {
    final int? address = _engineAddressOrNull;
    if (address == null) {
      return _pendingSeek ?? _position;
    }
    final Pointer<LazerAudioSnapshot> snapshot = _snapshotBuffer ??=
        calloc<LazerAudioSnapshot>();
    if (_api.snapshot(Pointer<Void>.fromAddress(address), snapshot) !=
        lazerAudioOk) {
      return _pendingSeek ?? _position;
    }
    final int millis = snapshot.ref.positionMillis;
    // A presented mix runs on the outgoing track's timeline, so the snapshot is
    // not the time the listener hears for the track the app now shows.
    if (_mixPresented) {
      _position = Duration(
        milliseconds: (millis - _mixStartOutgoingMillis).clamp(0, 1 << 30),
      );
      return _position;
    }
    if (millis >= 0) _position = Duration(milliseconds: millis);
    final int total = snapshot.ref.durationMillis;
    if (total > 0) _duration = Duration(milliseconds: total);
    final Duration? pending = _pendingSeek;
    if (pending != null) {
      final Duration age = Duration(
        microseconds:
            DateTime.now().microsecondsSinceEpoch - _pendingSeekAtMicros,
      );
      // Hold the requested target until the engine confirms the seek, because
      // until then the snapshot still describes the position *before* the jump.
      // A short hold — this used to be two seconds — is what made a slow seek
      // (or one into a region the decoder has to wait for) look like playback
      // had jumped back to where the reader was still working.
      if (age < seekHoldCeiling) return pending;
      _pendingSeek = null;
    }
    return _position;
  }

  /// Longest a requested seek target is published before the snapshot wins.
  ///
  /// The hold itself ends on `SeekCompleted`; this only bounds a callback that
  /// never arrives — a seek while paused, or a seek superseded by another.
  static const Duration seekHoldCeiling = Duration(seconds: 15);

  @override
  Duration? get duration {
    _readPosition();
    return _duration;
  }

  @override
  bool get seekIsLimitedByBuffer => _activeEntry?.complete == false;

  /// Whether [position] is inside the part of the current source that has landed.
  ///
  /// A streaming source is seeked only within its downloaded range: the download
  /// is the only source of bytes, so asking the engine for a position it cannot
  /// serve would park the decoder until the download catches up and then land
  /// somewhere else. A local file, or a fully downloaded stream, is seekable
  /// everywhere.
  @override
  bool canSeekTo(Duration position) {
    final AudioStreamEntry? entry = _activeEntry;
    if (entry == null) return true;
    if (entry.complete) return true;
    return position <= bufferedPosition;
  }

  @override
  Duration get bufferedPosition {
    _readPosition();
    final AudioStreamEntry? entry = _activeEntry;
    final Duration? total = _duration;
    if (entry == null) return total ?? _position;
    if (total == null || total == Duration.zero) {
      return _position;
    }
    final double? progress = entry.progress;
    // No announced length: the buffered position is unmeasurable, not zero. The
    // download bytes still exist, so the rail paints the playhead and the
    // startup path uses `streamedBytes` instead of this fraction.
    if (progress == null) return _position;
    final Duration buffered = total * progress;
    return buffered > _position ? buffered : _position;
  }

  @override
  Duration? get startupBufferedPosition {
    _readPosition();
    final entry = _activeEntry;
    if (entry != null &&
        !entry.complete &&
        (_duration == null || (entry.expectedBytes ?? 0) <= 0)) {
      // Both the length and the negotiated duration are still unknown, so there
      // is nothing to compare against: let the caller wait on streamed bytes.
      return null;
    }
    return bufferedPosition;
  }

  /// Bytes of the current network source that have landed on disk.
  @override
  int? get streamedBytes => _activeEntry?.downloadedBytes;

  /// Whether the download feeding the current source ended in failure.
  @override
  bool get streamFailed => _activeEntry?.failure != null;

  /// Whether no byte of the current download has landed for long enough that
  /// the reader is about to give up. Deliberately longer than the downloader's
  /// own no-data timeout (20 s), so the terminal failure is reported first and
  /// this only catches a download that is alive but delivering nothing.
  static const Duration streamStallTimeout = Duration(seconds: 25);

  @override
  bool get streamStalled =>
      _activeEntry?.stalledFor(streamStallTimeout) ?? false;

  /// Unblocks the decoder of a dead download by releasing the reader that is
  /// parked on it, then starts that download again from the bytes already on
  /// disk. Returns true when there was something to restart, in which case the
  /// caller is expected to reload the source so a fresh reader is bound.
  ///
  /// A decoder parked in `read` cannot be woken from Dart: the native reader
  /// only leaves that call on new bytes, its own stall deadline, or a close.
  /// Restarting therefore goes through [stop], which closes the reader on the
  /// worker thread — the same serialised path a track change uses.
  @override
  bool restartStream() {
    final int? address = _engineAddressOrNull;
    final AudioStreamEntry? entry = _activeEntry;
    final bool dead = streamFailed || streamStalled;
    if (address == null || entry == null) return false;
    if (!dead) {
      // The download is alive; only the watchdog clock needs resetting, which a
      // plain reopen of the same entry does without touching the reader.
      unawaited(
        _serialize(() async {
          try {
            await _cache.open(entry.url);
          } catch (_) {
            // A cache that refuses to reopen leaves the running download alone.
          }
        }),
      );
      return false;
    }
    // Invalidate the old source now. Calling stop inside the queued operation
    // would invalidate a newer setQueue request that is already waiting on it.
    final stopped = stop();
    unawaited(
      _serialize(() async {
        await stopped;
        try {
          await _cache.open(
            entry.url,
            expectedBytes: entry.expectedBytes,
            force: true,
          );
        } catch (error) {
          debugPrint('lazer-audio: restarting the stream failed: $error');
        }
      }),
    );
    return true;
  }

  int? get _engineAddressOrNull =>
      _engineAddress == 0 || _ownershipFaulted ? null : _engineAddress;

  /// Re-reads the negotiated format; also refreshes [streamInfo].
  LazerStreamInfo? readStreamInfo() {
    if (!_sourceLoaded) return null;
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

  /// Ring occupancy and starvation accounting for the current session.
  ///
  /// Synchronous and cheap on purpose — the same snapshot call [position] already
  /// makes — so the diagnostics panel can read it while it builds. Returns null
  /// when no engine session exists.
  LazerEngineMetrics? readMetrics() {
    final int? address = _engineAddressOrNull;
    if (address == null) return null;
    final Pointer<LazerAudioSnapshot> snapshot = _snapshotBuffer ??=
        calloc<LazerAudioSnapshot>();
    if (_api.snapshot(Pointer<Void>.fromAddress(address), snapshot) !=
        lazerAudioOk) {
      return null;
    }
    return LazerEngineMetrics.fromNative(snapshot.ref);
  }

  @override
  Future<void> setUrl(String url) {
    final int generation = ++_generation;
    _interruptPendingReads();
    _sourceLoaded = false;
    _publishStreamInfo(null);
    _mixPresented = false;
    _completionSent = false;
    _pendingUrls = <String>[];
    return _serialize(
      () async {
        await _clearQueued();
        if (generation != _generation) return;
        await _openSource(url, generation);
      },
      key: 'source',
      onSuperseded: () {},
      essential: true,
    );
  }

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    final int queueId = ++_queueId;
    final int generation = ++_generation;
    _interruptPendingReads();
    _sourceLoaded = false;
    _publishStreamInfo(null);
    _mixPresented = false;
    _completionSent = false;
    if (urls.isEmpty) {
      _pendingUrls = <String>[];
      _position = Duration.zero;
      _duration = null;
      _pendingSeek = null;
      await _serialize(
        () async {
          if (generation != _generation || _disposed) return;
          await _stopSource(generation);
        },
        key: 'source',
        onSuperseded: () {},
        essential: true,
      );
      return queueId;
    }
    final int index = startIndex.clamp(0, urls.length - 1);
    _queueIndex = index;
    _pendingUrls = urls.sublist(index + 1);
    final String source = urls[index];
    await _serialize(
      () async {
        await _clearQueued();
        if (generation != _generation) return;
        await _openSource(source, generation);
      },
      key: 'source',
      onSuperseded: () {},
      essential: true,
    );
    return queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async {
    if (queueId != _queueId || !_sourceLoaded || _bridge == null) return false;
    // While an overlap is audible the successor is the song being mixed in.
    // Preparing another one would replace it — the engine refuses a second
    // successor, and the preparation that loses that race clears the queued
    // reader, which fades the incoming song back out. The app asks again once the
    // hand-off completes.
    if (_mixPresented) return false;
    _pendingUrls = <String>[url];
    // Replacing a successor the engine already holds: it keeps exactly one, and
    // asking for a second fails and clears the queued reader instead — which
    // would leave the app waiting for a hand-off the engine can no longer make.
    // Drop the old one first, then prepare the new one.
    if (_queued != null) {
      await _clearQueued();
      if (queueId != _queueId || !_sourceLoaded || _disposed) return false;
    }
    // Separate from transport mutations: a skip can still interrupt the reader.
    // Await retirement so a later mode refresh cannot clear a new preparation
    // while this one's superseded-reader cleanup is still running.
    final int generation = _generation;
    final bool prepared = await _prepareSuccessor(url);
    return prepared &&
        generation == _generation &&
        queueId == _queueId &&
        !_disposed;
  }

  @override
  Future<bool> clearQueued(int queueId) {
    final int generation = _generation;
    // Put the clear itself on the preparation lane. Waiting on an idle future
    // would also wait for later appends, then accidentally erase their reader.
    return _preparationQueue.run(
      () => _serialize(() async {
        if (_disposed ||
            generation != _generation ||
            queueId != _queueId ||
            !_sourceLoaded ||
            _mixPresented) {
          return false;
        }
        // Older imported engines cannot preserve an overlap atomically. Keep
        // their accepted successor and apply the new mode after its hand-off.
        if (_api.clearUnheardQueuedReader == null) return false;
        final int? address = _engineAddressOrNull;
        if (address == null) return false;
        final int result = _status(
          await _callWorker(LazerWorkerOp.clearQueuedReader, <Object?>[
            address,
            ++_queueGeneration,
            true,
          ]),
        );
        if (_disposed || generation != _generation || queueId != _queueId) {
          return false;
        }
        if (result == lazerAudioQueueAlreadyAudible) return false;
        if (result == lazerAudioQueueAlreadyActive) {
          final bool announced = _mixPresented;
          _mixPresented = false;
          _crossIntoSuccessor(position.inMilliseconds, announce: !announced);
          return false;
        }
        if (result != lazerAudioOk && result != lazerAudioErrorState) {
          throw StateError('Could not clear the successor ($result)');
        }
        _pendingUrls = <String>[];
        final _SuccessorBinding? queued = _queued;
        _queued = null;
        queued?.reader.release();
        queued?.entry?.cancelIfUnleased();
        return true;
      }),
      key: 'clear',
      onSuperseded: () => false,
      essential: true,
    );
  }

  /// The URL this engine has prepared as its successor, or null when it holds
  /// none.
  ///
  /// The app binds a queue index to the URL it appended and reads it back when
  /// the engine crosses, which is what makes "the mixed-in song is the one the
  /// queue scripted" checkable.
  @override
  String? get queuedSourceUrl => _queued?.url;

  /// Whether the successor is already audible inside an overlap.
  @override
  bool get mixPresented => _mixPresented;

  @override
  Future<bool> playQueuedNext() async {
    final bool fromPending = _queued == null;
    final pending = _pendingUrls;
    final String? next = _queued?.url ?? _pendingUrls.firstOrNull;
    if (next == null) return false;
    final int generation = ++_generation;
    _sourceLoaded = false;
    _publishStreamInfo(null);
    _interruptPendingReads();
    return _serialize(() async {
      await _clearQueued();
      if (generation != _generation) return false;
      _queueIndex++;
      await _openSource(next, generation);
      if (fromPending &&
          generation == _generation &&
          identical(_pendingUrls, pending) &&
          _pendingUrls.firstOrNull == next) {
        _pendingUrls = _pendingUrls.skip(1).toList();
      }
      return generation == _generation;
    });
  }

  @override
  Future<void> play() async {
    final int generation = _generation;
    final int request = ++_transportRequest;
    final int? address = _engineAddressOrNull;
    if (_disposed) return;
    if (address == null || !_sourceLoaded) {
      throw StateError('lazer-audio: play requested without a loaded source');
    }
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
      await _callWorker(LazerWorkerOp.play, [address]),
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
    await _callWorker(LazerWorkerOp.pause, [address]);
  }

  @override
  Future<void> seek(Duration position) async {
    final int generation = _generation;
    final int? address = _engineAddressOrNull;
    if (address == null || position < Duration.zero) return;
    if (!canSeekTo(position)) {
      // Outside what the download has landed: the reader would park the decoder
      // until the download catches up and then land somewhere else, which is worse
      // than refusing. The caller reports it and the rail snaps back to its real
      // position.
      throw StateError(
        'lazer-audio: ${position.inMilliseconds} ms is not downloaded yet '
        '(${bufferedPosition.inMilliseconds} ms is)',
      );
    }
    final int status = _status(
      await _callWorker(LazerWorkerOp.seek, [address, position.inMilliseconds]),
    );
    if (status != lazerAudioOk || generation != _generation || _disposed) {
      return;
    }
    // A seek cancels an overlap that is playing: the engine drops the incoming
    // side and keeps the successor queued, so the outgoing song is what is heard
    // again and the position is back on its timeline. The app notices the same
    // thing through [mixPresented] before it asks for the seek. Cleared only once
    // the engine confirmed the seek: a refused one left the overlap playing, and
    // the position would then be read from the wrong timeline.
    _mixPresented = false;
    _position = position;
    // The engine's published position only moves once the decode side applied
    // the seek; reporting the target meanwhile keeps the rail from jumping back.
    _pendingSeek = position;
    _pendingSeekAtMicros = DateTime.now().microsecondsSinceEpoch;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!volume.isFinite) {
      throw ArgumentError.value(volume, 'volume', 'must be finite');
    }
    final double requested = volume.clamp(0, 1);
    final int? address = _engineAddressOrNull;
    if (address == null) {
      _volume = requested;
      _volumeNotice = null;
      return;
    }
    final int status = _status(
      await _callWorker(LazerWorkerOp.setVolume, <Object?>[address, requested]),
    );
    if (status == lazerAudioOk) {
      _volume = requested;
      _volumeNotice = null;
      return;
    }
    // Direct output refuses software volume. Keep the engine's real level so
    // the mixer and the UI agree; the app reports the refusal instead of
    // persisting a level that is not being played.
    _volumeNotice = lastError();
  }

  @override
  double get appliedVolume => _volume;

  @override
  String? get volumeNotice => _volumeNotice;
  String? _volumeNotice;

  bool get supportsAutoMix => _api.setAutoMix != null;

  /// Configure before opening a source: AutoMix uses two PCM decoders feeding
  /// the existing output device, including when that device is exclusive.
  /// An existing source needs reopening to renegotiate its PCM format.
  /// The overlap the transition uses, in milliseconds.
  ///
  /// The reference player's natural mode picks five seconds (its candidate set is
  /// 1-13 s), which is long enough to be a real blend and short enough that two
  /// songs never fight for the floor.
  static const int autoMixOverlapMillis = 5000;

  @override
  Future<void> setAutoMixEnabled(bool enabled, {Duration? duration}) async {
    if (!supportsAutoMix) {
      if (enabled) {
        throw UnsupportedError('This audio engine has no overlap mixer.');
      }
      return;
    }
    final int? address = _engineAddressOrNull;
    if (address == null) return;
    final int overlapMs = (duration?.inMilliseconds ?? autoMixOverlapMillis)
        .clamp(1000, 13000);
    final int status = _status(
      await _callWorker(LazerWorkerOp.setAutoMix, <Object?>[
        address,
        enabled ? overlapMs : 0,
      ]),
    );
    if (status != lazerAudioOk) {
      throw StateError(
        'Could not configure overlap mixing ($status): ${lastError()}',
      );
    }
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
    final String? token = await _resolveDeviceToken(settings);
    if (_disposed || !identical(settings, _deviceSettings)) return;
    final int status = _status(
      await _callWorker(LazerWorkerOp.setDevice, <Object?>[
        address,
        ...settings.toDeviceMessage(),
        token,
      ]),
    );
    // A running source applies the selection on its next open. Every other
    // refusal must reach the settings UI instead of looking successfully applied.
    if (status != lazerAudioOk && status != lazerAudioErrorState) {
      throw StateError(
        'Output settings were refused ($status): ${lastError()}',
      );
    }
  }

  Future<String?> _resolveDeviceToken(LazerDeviceSettings settings) async {
    final String? token = settings.deviceToken;
    if (defaultTargetPlatform != TargetPlatform.android ||
        token == null ||
        !token.startsWith('android-usb')) {
      return token;
    }
    if (!_api.supportsAndroidUsb) {
      throw UnsupportedError(
        'This audio engine has no Android USB output backend.',
      );
    }
    final usb = AndroidUsbAudio.instance;
    final int generation = _generation;
    final String resolved = await usb.resolveDeviceId(token);
    _usbConnectionsOpened = true;
    if (_disposed || settings.deviceToken != _deviceSettings.deviceToken) {
      // Android caches one connection per device. A superseded request can
      // resolve to the FD still used by the current native output, so retain it
      // until native destruction. A permission result arriving after destruction
      // is too late for shutdown's closeAll and must release its connection here.
      if (_nativeDestroyed) await usb.releaseDevice(token);
      throw StateError('The USB output request was cancelled.');
    }
    if (generation != _generation) {
      // A newer source may be using this same connection. Retain its ownership
      // until shutdown, but never apply the old source's request to it.
      throw StateError('The USB output request was superseded.');
    }
    _usbDetachSubscription ??= usb.detachedDevices.listen((deviceId) {
      if (!_disposed && deviceId == _deviceSettings.deviceToken) {
        _reportFailure(
          'The USB audio device was disconnected.',
          AudioFailureKind.device,
        );
      }
    });
    return resolved;
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
    List<int> stageOrder = const <int>[],
  }) async {
    final int? address = _engineAddressOrNull;
    if (address == null) return;
    final List<Object?> settings = <Object?>[
      preampDb,
      limiterEnabled ? 1 : 0,
      limiterThresholdDb,
      <Object?>[for (final LazerEqBandSettings band in bands) band.toMessage()],
      crossfeed.toMessage(),
      List<int>.of(stageOrder),
    ];
    _pendingDspSettings = settings;
    final int status = _status(
      await _callWorker(LazerWorkerOp.setDsp, <Object?>[address, ...settings]),
    );
    if (status != lazerAudioOk) {
      throw StateError('DSP settings were refused ($status): ${lastError()}');
    }
    if (identical(_pendingDspSettings, settings)) _pendingDspSettings = null;
  }

  /// Deletes the audio cache; playback stops because its files are gone.
  Future<int> clearCache() async {
    await stop();
    return _cache.clear();
  }

  @override
  Future<void> stop() {
    final int generation = ++_generation;
    _interruptPendingReads();
    _sourceLoaded = false;
    _mixPresented = false;
    _completionSent = false;
    _pendingUrls = <String>[];
    _position = Duration.zero;
    _pendingSeek = null;
    _duration = null;
    return _serialize(
      () => _stopSource(generation),
      key: 'source',
      onSuperseded: () {},
      essential: true,
    );
  }

  Future<void> _stopSource(int generation) async {
    final int? address = _engineAddressOrNull;
    if (address != null) {
      try {
        // Serialised: after this returns the engine no longer reads any source,
        // so the readers and cache entries can be dropped.
        final stopped = _status(
          await _callWorker(LazerWorkerOp.stop, <Object?>[address]),
        );
        if (stopped != lazerAudioOk) {
          _faultWorker();
          return;
        }
      } catch (error) {
        debugPrint('lazer-audio: stop failed: $error');
        return; // No ownership acknowledgement: keep every reader alive.
      }
    }
    if ((_ownershipFaulted || _shutdownStarted) && !_nativeDestroyed) return;
    // A stop retires every source of the generation it names, so a reader that
    // was deferred for lack of proof can be dropped now; an install only
    // retires the generations before it.
    _confirmSourceTransition(generation, retiresGeneration: true);
    // Issuing a second clear here reports ErrorState (there is nothing queued)
    // and used to fault the worker before Dart released either reader.
    _releaseQueued();
    if ((_ownershipFaulted || _shutdownStarted) && !_nativeDestroyed) return;
    _releaseActive();
    _publishStreamInfo(null);
  }

  @override
  void dispose() {
    unawaited(_shutdown());
  }

  Future<void> _shutdown() => _shutdownFuture ??= _shutdownImpl();

  Future<Object?> _callWorker(int op, List<Object?> params) async {
    if (_ownershipFaulted || _shutdownStarted) {
      throw const LazerWorkerNotSubmitted(
        'native audio ownership is unconfirmed',
      );
    }
    try {
      return await _worker.call(op, params);
    } catch (error) {
      if (error is! LazerWorkerNotSubmitted) _faultWorker();
      rethrow;
    }
  }

  void _cancelOwnedReaders() {
    final readers = <NativeStreamReader>{
      ?_activeReader,
      ?_queued?.reader,
      ?_openingReader,
      ..._preparingReaders,
      ..._deferredReaderRetirements.map((retirement) => retirement.reader),
      ..._unconfirmedReaders,
    };
    for (final reader in readers) {
      reader.cancel();
    }
  }

  void _faultWorker() {
    if (_ownershipFaulted) return;
    _ownershipFaulted = true;
    _workerFailure = 'Native audio worker failed; playback has been stopped.';
    _logTimer?.cancel();
    _sourceLoaded = false;
    _cancelOwnedReaders();
    _publishStreamInfo(null);
    _reportFailure(_workerFailure!, AudioFailureKind.unknown);
    unawaited(_shutdown());
  }

  void _retireOrHold(NativeStreamReader reader) {
    if ((_ownershipFaulted || _shutdownStarted) && !_nativeDestroyed) {
      // Source and successor lanes admit at most four distinct native readers;
      // faulting disables both lanes before another reader can be created.
      _unconfirmedReaders.add(reader);
    } else {
      reader.release();
    }
  }

  Future<void> _shutdownImpl() async {
    _shutdownStarted = true;
    _logTimer?.cancel();
    _drainLogs();
    _disposed = true;
    _operationQueue.cancelPending();
    _preparationQueue.cancelPending();
    ++_generation;
    _interruptPendingReads();
    _sourceLoaded = false;
    final int? address = _engineAddress == 0 ? null : _engineAddress;
    _cancelOwnedReaders();
    // Let the mutation chain and any successor preparation finish (bounded, so a
    // download that never delivers cannot hang shutdown) before the engine is
    // destroyed.
    await _operations.timeout(const Duration(seconds: 5), onTimeout: () {});
    await _awaitPreparations();
    _engineAddress = 0;
    if (!_creationInDoubt) {
      if (address == null) {
        _nativeDestroyed = true;
      } else if (!_ownershipFaulted) {
        try {
          final stopped = _status(
            await _worker
                .call(LazerWorkerOp.stop, [address])
                .timeout(_teardownTimeout),
          );
          if (stopped != lazerAudioOk) {
            throw StateError('native stop was not acknowledged');
          }
          _destroyRequested = true;
          await _worker
              .call(LazerWorkerOp.destroy, [address])
              .timeout(_teardownTimeout);
          _nativeDestroyed = true;
        } catch (error) {
          debugPrint('lazer-audio: shutdown failed: $error');
        }
      }
      if (!_nativeDestroyed && !_destroyRequested && address != null) {
        try {
          // Kill is only a request. Await confirmed isolate exit before a
          // synchronous fallback can touch the same engine pointer.
          await _worker.close().timeout(_teardownTimeout);
          final stop = _api.stop;
          final destroy = _api.destroy;
          final pointer = Pointer<Void>.fromAddress(address);
          if (stop(pointer) != lazerAudioOk) {
            throw StateError('fallback stop failed');
          }
          _destroyRequested = true;
          destroy(pointer);
          _nativeDestroyed = true;
        } catch (error) {
          debugPrint(
            'lazer-audio: native teardown could not be confirmed: $error',
          );
        }
      }
    }
    await _usbDetachSubscription?.cancel();
    _usbDetachSubscription = null;
    if (!_nativeDestroyed) {
      // A destroy request may already have executed despite its missing reply.
      // Never retry that pointer, close its callbacks, or free its readers.
      _ownershipFaulted = true;
      _workerFailure =
          'Native audio cleanup could not be confirmed; restart the app.';
      _ownershipBudget.retain(this); // Exactly one retained owner per process.
      _reportFailure(_workerFailure!, AudioFailureKind.unknown);
      _cache.close();
      try {
        await _worker.close().timeout(_teardownTimeout);
      } catch (_) {}
      return;
    }
    if (_usbConnectionsOpened && _nativeDestroyed) {
      // Java's connection owns the FD: close it only after native output stops.
      try {
        await AndroidUsbAudio.instance.closeConnections();
      } catch (error) {
        debugPrint('lazer-audio: closing USB connections failed: $error');
      }
      _usbConnectionsOpened = false;
    }
    // Readers are only freed once the engine has joined its threads.
    _releaseActive();
    final _SuccessorBinding? queued = _queued;
    _queued = null;
    queued?.reader.release();
    queued?.entry?.cancelIfUnleased();
    _releaseDeferredReaders();
    for (final reader in _unconfirmedReaders) {
      reader.release();
    }
    _unconfirmedReaders.clear();
    _ownershipBudget.release(this);
    try {
      await _worker.close().timeout(_teardownTimeout);
    } catch (_) {}
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

  Future<T> _serialize<T>(
    Future<T> Function() operation, {
    Object? key,
    T Function()? onSuperseded,
    bool essential = false,
  }) => _operationQueue.run(
    operation,
    key: key,
    onSuperseded: onSuperseded ?? () => (T == bool ? false : null) as T,
    essential: essential,
  );

  void _interruptPendingReads() {
    // Enqueuing this wake-up behind the blocked open/queue would deadlock it.
    if (_openingReader == null && _preparingReaders.isEmpty) return;
    logAudioPathEvent('source_cancel', {
      'generation': _generation,
      'opening': _openingReader != null,
      'preparing': _preparingReaders.length,
    });
    _openingReader?.cancel();
    for (final reader in _preparingReaders) {
      reader.cancel();
    }
  }

  /// Opens [url] as the audible source; [generation] rejects superseded opens.
  Future<void> _openSource(String url, int generation) async {
    if (generation != _generation || _disposed) return;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // RemoteIO's open reads the session's actual route and sample clock.
      // Configure its category before that open, while leaving focus activation
      // to play(). Preloading must not acquire focus or reject an existing source.
      await prepareSession?.call();
      if (generation != _generation || _disposed) return;
    }
    AudioStreamLease? lease = await _cacheLeaseFor(url);
    final AudioStreamEntry? entry = lease?.entry;
    NativeStreamReader? reader;
    try {
      if (generation != _generation || _disposed) return;
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
        // The size arrives with the response headers. A demuxer needs it to turn
        // a seek's timestamp into a byte offset, so the reader is created with it
        // when it is known by now.
        final int? length = await entry.expectedLengthWithin(sourceLengthWait);
        if (generation != _generation || _disposed) return;
        reader = NativeStreamReader.create(
          bridge,
          path: entry.file.path,
          expectedBytes: length ?? entry.expectedBytes,
          onReleased: lease?.release,
        );
        if (reader == null) {
          throw StateError('the reader bridge rejected ${entry.file.path}');
        }
        _openingReader = reader;
        _connectEntry(lease!, reader);
        lease =
            null; // The reader releases this lease after native stops using it.
      }

      final int status = await _openWithDsdPolicy(
        address: address,
        path: entry == null ? _localPath(url) : null,
        reader: reader,
        generation: generation,
      );
      if (status != lazerAudioOk) {
        final String detail = lastError();
        AppLog.shared.event('audio.native', 'open_failed', {
          'status': status,
          'detail': detail,
          'network': entry != null,
          'downloaded_bytes': entry?.downloadedBytes,
          'expected_bytes': entry?.expectedBytes,
          'download_error': entry?.failure?.toString(),
        });
        if (entry != null &&
            generation == _generation &&
            (status == lazerAudioErrorSource ||
                status == lazerAudioErrorDecode)) {
          // The engine rejected the source and has closed this reader. Release
          // its OS file handle before removing a complete but invalid response.
          reader?.release();
          try {
            await _cache.discardRejectedComplete(entry);
          } catch (error) {
            AppLog.shared.event('audio.native', 'cache_discard_failed', {
              'error': error.toString(),
            });
          }
        }
        final String message =
            'lazer-audio could not open source ($status): $detail';
        final bool directOutput =
            _deviceSettings.bitPerfect ||
            (_deviceSettings.dsdAttempts.length == 1 &&
                _deviceSettings.dsdOutputMode !=
                    lazerAudioDsdOutputConvertToPcm);
        if (directOutput &&
            (status == lazerAudioErrorUnsupported ||
                status == lazerAudioErrorDevice)) {
          throw AudioOutputRefused(message);
        }
        throw StateError(message);
      }
      // The engine just accepted this source, so whatever was active before is
      // gone and its reader can be freed now.
      _confirmSourceTransition(generation);
      _releaseActive(keepEntry: entry);
      _activeEntry = entry;
      _activeReader = reader;
      _emitBufferChange();
      _sourceLoaded = generation == _generation && !_disposed;
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
      if (reader != null) _retireOrHold(reader);
      entry?.cancelIfUnleased();
      if (generation == _generation) {
        _sourceLoaded = false;
        // The failed replacement has no negotiated output. A cached strict
        // USB verdict belongs to the previous source, never to this refusal.
        _publishStreamInfo(null);
      }
      rethrow;
    } finally {
      lease?.release();
      if (identical(_openingReader, reader)) _openingReader = null;
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
      if (generation != _generation || _disposed) return lazerAudioErrorState;
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
        await _callWorker(LazerWorkerOp.openFile, <Object?>[
          address,
          path,
          ...const LazerOpenSettings().toMessage(),
        ]),
      );
    }
    return _status(
      await _callWorker(LazerWorkerOp.openReader, <Object?>[
        address,
        reader!.address,
        ...const LazerOpenSettings().toMessage(),
      ]),
    );
  }

  /// Applies the output policy; [dsdOverride] replaces the DSD field for one
  /// attempt of the auto chain.
  Future<void> _applyOutputSettings(int address, {int? dsdOverride}) async {
    final LazerDeviceSettings settings = _deviceSettings;
    final String? token = await _resolveDeviceToken(settings);
    if (_disposed) return;
    final List<Object?> message = settings.toDeviceMessage();
    if (dsdOverride != null) message[5] = dsdOverride;
    Future<int> apply() async => _status(
      await _callWorker(LazerWorkerOp.setDevice, <Object?>[
        address,
        ...message,
        token,
      ]),
    );
    int status = await apply();
    if (status == lazerAudioErrorState) {
      // A source is still open, and the engine accepts a new device config only
      // while idle/stopped. Without this stop the previous session's format,
      // buffer, exclusive mode and DSD policy stayed in force for the rest of
      // the launch: every settings change after the first track was ignored.
      final int stopStatus = _status(
        await _callWorker(LazerWorkerOp.stop, <Object?>[address]),
      );
      if (stopStatus != lazerAudioOk) {
        throw AudioOutputRefused(
          'Could not stop the previous output ($stopStatus): ${lastError()}',
        );
      }
      status = await apply();
    }
    if (status != lazerAudioOk) {
      throw AudioOutputRefused(
        'Output settings were refused ($status): ${lastError()}',
      );
    }
    // Leaving a strict track queues a normal output policy, but the old stream
    // still refuses DSP until it is stopped above. Replay that refused request
    // here so the next ordinary track restores the user's saved EQ and gain.
    final List<Object?>? pendingDsp = _pendingDspSettings;
    if (pendingDsp != null) {
      final int dspStatus = _status(
        await _callWorker(LazerWorkerOp.setDsp, <Object?>[
          address,
          ...pendingDsp,
        ]),
      );
      if (dspStatus != lazerAudioOk) {
        throw AudioOutputRefused(
          'DSP settings were refused ($dspStatus): ${lastError()}',
        );
      }
      if (identical(_pendingDspSettings, pendingDsp)) {
        _pendingDspSettings = null;
      }
    }
    final int volumeStatus = _status(
      await _callWorker(LazerWorkerOp.setVolume, <Object?>[address, _volume]),
    );
    if (volumeStatus != lazerAudioOk) {
      throw AudioOutputRefused(
        'Volume settings were refused ($volumeStatus): ${lastError()}',
      );
    }
  }

  /// Prepares [url] as the successor inside the running output session.
  ///
  /// Detached from the mutation chain on purpose: `queue_reader` decodes the
  /// successor, which waits for its bytes. Whoever loses the race — because the
  /// queue was replaced, the source stopped, or the app moved on — frees its own
  /// reader only after a later serialised call has made the engine drop it.
  Future<bool> _prepareSuccessor(String url) {
    final int sourceGeneration = _generation;
    final int requestGeneration = ++_successorRequestGeneration;
    return _preparationQueue.run(
      () async {
        if (sourceGeneration != _generation ||
            requestGeneration != _successorRequestGeneration ||
            _disposed) {
          return false;
        }
        return _prepareSuccessorImpl(url, sourceGeneration, requestGeneration);
      },
      key: 'successor',
      onSuperseded: () => false,
    );
  }

  Future<bool> _prepareSuccessorImpl(
    String url,
    int sourceGeneration,
    int requestGeneration,
  ) async {
    final LazerAudioBridgeApi? bridge = _bridge;
    final int? address = _engineAddressOrNull;
    if (bridge == null || address == null || !_sourceLoaded || _disposed) {
      return false;
    }
    _preparationsInFlight++;
    AudioStreamEntry? entry;
    AudioStreamLease? lease;
    NativeStreamReader? reader;
    NativeStreamReader? preparingReader;
    // The generation this reader is queued under, kept outside the block that
    // declares it so a lost reply can still name the resource to clear.
    int queuedGeneration = 0;
    bool submitted = false;
    try {
      lease = await _cacheLeaseFor(url);
      entry = lease?.entry;
      final String path = entry?.file.path ?? _localPath(url);
      final int? expectedBytes = entry == null
          ? await File(path).length()
          // A successor is decoded ahead of its audible boundary, so waiting for
          // the announced size costs nothing the mix needs.
          : await entry.expectedLengthWithin(successorLengthWait) ??
                entry.expectedBytes;
      if (requestGeneration != _successorRequestGeneration ||
          sourceGeneration != _generation ||
          !_sourceLoaded ||
          _disposed) {
        return false;
      }
      // A reader whose exact clear answered `ErrorState` still occupies the
      // engine's successor slot: the refusal means the engine did not act, not
      // that the slot is free. Free it before asking for another successor or
      // the engine refuses this request as a second one.
      if (_successorSlotUnconfirmed) {
        await _clearQueued();
        if (requestGeneration != _successorRequestGeneration ||
            sourceGeneration != _generation ||
            !_sourceLoaded ||
            _disposed) {
          return false;
        }
      }
      // Keep repeat-one and adjacent copies of the audible URL pending, as in
      // ordinary repeat playback. Reopen after completion (or manual skip)
      // instead of asking the native engine to prepare the same source twice.
      if (entry != null && identical(entry, _activeEntry)) {
        // A different successor may already be prepared (for example before
        // repeat-one was selected). Drop it while keeping this pending repeat.
        await _clearQueued();
        return false;
      }
      reader = NativeStreamReader.create(
        bridge,
        path: path,
        expectedBytes: expectedBytes,
        onReleased: lease?.release,
      );
      if (reader == null) return false;
      preparingReader = reader;
      _preparingReaders.add(reader);
      // The cache download can finish after this local is transferred into
      // `_queued` and set to null below. Capture the reader itself so the
      // completion callback still signals the bridge instead of throwing from
      // the cache's unawaited download future.
      final NativeStreamReader queuedReader = reader;
      if (lease != null) _connectEntry(lease, queuedReader);
      lease = null;
      if (entry == null) queuedReader.finish();
      final int generation = queuedGeneration = ++_queueGeneration;
      submitted = true;
      final int status = _status(
        await _callWorker(LazerWorkerOp.queueReader, <Object?>[
          address,
          generation,
          reader.address,
          ...const LazerOpenSettings().toMessage(),
        ]),
      );
      if (status != lazerAudioOk ||
          requestGeneration != _successorRequestGeneration ||
          generation != _queueGeneration ||
          sourceGeneration != _generation ||
          !_sourceLoaded ||
          _disposed) {
        if (status < 0) {
          // An explicit queue rejection never installed this reader. A lost RPC
          // reply is handled by the catch path and has unknown ownership.
          _retireOrHold(reader);
        } else if (sourceGeneration != _generation) {
          // queue_reader completed before the newer source operation reached
          // the worker (the worker serialises calls). Keep the installed reader
          // alive until that stop/open confirms it retired the old session.
          _deferSupersededReader(
            reader,
            entry,
            url,
            sourceGeneration,
            generation,
          );
        } else {
          await _settleSupersededReader(
            address,
            reader,
            entry,
            url,
            sourceGeneration,
            generation,
          );
        }
        reader = null;
        entry = null;
        return false;
      }
      _queued?.reader.release();
      _queued?.entry?.cancelIfUnleased();
      // The binding a later exact clear has to name: which source generation
      // this successor belongs to, and the queue generation it was installed
      // with. Without them a clear can only say "drop the queue", which frees a
      // different reader than the one this call owns.
      _queued = _SuccessorBinding(
        reader,
        entry,
        url,
        sourceGeneration,
        generation,
      );
      // appendToQueue keeps the URL available while preparation is pending so
      // a manual skip can still open it. Once prepared, the reader owns it;
      // leaving it pending would prepare the same song again at its boundary,
      // racing the app's next prefetch and rebinding the active cache reader.
      if (_pendingUrls.firstOrNull == url) {
        _pendingUrls = _pendingUrls.skip(1).toList();
      }
      reader = null;
      entry = null;
      return true;
    } catch (error) {
      debugPrint('lazer-audio: preparing $url failed: $error');
      if (reader != null) {
        if (error is LazerWorkerNotSubmitted) {
          _retireOrHold(reader);
        } else if (submitted) {
          // The call reached the worker but its reply was lost, so the engine may
          // have installed this reader. Name it explicitly instead of releasing a
          // reader the engine might still be decoding from.
          await _settleSupersededReader(
            address,
            reader,
            entry,
            url,
            sourceGeneration,
            queuedGeneration,
          );
        } else {
          _retireOrHold(reader);
        }
      }
      return false;
    } finally {
      lease?.release();
      _preparingReaders.remove(preparingReader);
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
  /// an *exact* clear that names the queue generation it was installed under: it
  /// runs on the same worker isolate as the `queue_reader` that installed it, so
  /// an `Ok` proves the engine is no longer calling that reader. The older
  /// `clear_queued_reader` cannot stand in here — it drops whatever the queue
  /// holds now, which may be a different, newer successor.
  ///
  /// `QueueAlreadyActive` means the successor crossed the audible boundary and is
  /// adopted here; `QueueAlreadyAudible` means it is still queued and is retained
  /// with a fresh binding; `ErrorState` means the request was stale and the
  /// engine may still own the reader, so it stays deferred until a source
  /// transition confirms the engine moved on.
  Future<void> _settleSupersededReader(
    int address,
    NativeStreamReader reader,
    AudioStreamEntry? entry,
    String url,
    int sourceGeneration,
    int targetQueueGeneration,
  ) async {
    if (_ownershipFaulted || _shutdownStarted) {
      _retireOrHold(reader);
      return;
    }
    final int requestGeneration = ++_queueGeneration;
    int result = lazerAudioErrorState;
    try {
      result = _status(
        await _callWorker(LazerWorkerOp.clearQueuedReaderEx, <Object?>[
          address,
          targetQueueGeneration,
          requestGeneration,
          false,
        ]),
      );
    } catch (error) {
      debugPrint('lazer-audio: clearing a superseded reader failed: $error');
      _retireOrHold(reader);
      return;
    }
    if (result < 0 && result != lazerAudioErrorState) {
      _faultWorker();
      _retireOrHold(reader);
      return;
    }
    if (_generation != sourceGeneration) {
      // A source transition followed this clear on the worker lane. If the
      // clear found the reader active or audible, the transition will retire
      // it; until the transition is acknowledged it must stay alive.
      if (result == lazerAudioQueueAlreadyActive ||
          result == lazerAudioQueueAlreadyAudible ||
          result == lazerAudioErrorState) {
        _deferSupersededReader(
          reader,
          entry,
          url,
          sourceGeneration,
          requestGeneration,
        );
      } else {
        _retireOrHold(reader);
        entry?.cancelIfUnleased();
      }
      return;
    }
    if (result == lazerAudioQueueAlreadyActive) {
      _adoptActiveReader(reader, entry);
      return;
    }
    if (result == lazerAudioQueueAlreadyAudible) {
      _retainQueuedReader(
        reader,
        entry,
        url,
        sourceGeneration,
        requestGeneration,
      );
      return;
    }
    if (result == lazerAudioErrorState) {
      // Stale request: the engine did not act, so it may still be calling this
      // reader. Free it only once a transition proves the old session is gone.
      _deferSupersededReader(
        reader,
        entry,
        url,
        sourceGeneration,
        requestGeneration,
      );
      return;
    }
    reader.release();
    entry?.cancelIfUnleased();
  }

  void _adoptActiveReader(NativeStreamReader reader, AudioStreamEntry? entry) {
    final NativeStreamReader? previousReader = _activeReader;
    final AudioStreamEntry? previousEntry = _activeEntry;
    _activeReader = reader;
    _activeEntry = entry;
    if (_queued != null && identical(_queued!.reader, reader)) {
      _queued = null;
    }
    _sourceLoaded = !_disposed;
    _completionSent = false;
    _mixPresented = false;
    _pendingSeek = null;
    _queueIndex++;
    if (!identical(previousReader, reader)) {
      previousReader?.release();
      previousEntry?.cancelIfUnleased();
    }
    _emitBufferChange();
    _publishStreamInfo(readStreamInfo());
    if (!_disposed && !_advanced.isClosed) _advanced.add(_queueIndex);
  }

  void _retainQueuedReader(
    NativeStreamReader reader,
    AudioStreamEntry? entry,
    String url,
    int sourceGeneration,
    int queueGeneration,
  ) {
    final _SuccessorBinding? previous = _queued;
    _queued = _SuccessorBinding(
      reader,
      entry,
      url,
      sourceGeneration,
      queueGeneration,
    );
    if (previous != null && !identical(previous.reader, reader)) {
      // Native allows only one installed successor. Retaining the previous
      // reference until the next source transition is conservative if an older
      // library reports a contradictory audible result.
      _deferSupersededReader(
        previous.reader,
        previous.entry,
        previous.url,
        sourceGeneration,
        queueGeneration,
      );
    }
  }

  /// Drops the prepared successor and its cache entry.
  ///
  /// Unlike the exact clear in [_settleSupersededReader] this one names no
  /// target: it asks the engine to drop whatever the queue holds now, which is
  /// what cancelling a prefetch means. It is sent even when no reader is
  /// installed yet — a preparation may still be inside the worker, and the
  /// bumped request generation makes that later `queue_reader` stale.
  Future<void> _clearQueued() async {
    if ((_ownershipFaulted || _shutdownStarted) && !_nativeDestroyed) return;
    final int? address = _engineAddressOrNull;
    final int generation = ++_queueGeneration;
    // Nothing installed and nothing in flight: there is no request to cancel, so
    // an RPC here would only churn the engine's generation bookkeeping.
    final bool canCancel =
        _queued != null ||
        _preparationsInFlight > 0 ||
        _pendingUrls.isNotEmpty ||
        _successorSlotUnconfirmed;
    if (address != null && canCancel) {
      // With a live binding the exact clear can name the successor this isolate
      // owns, so a newer successor queued behind it is not dropped by mistake.
      // Without one (nothing installed yet, or the session changed) the unnamed
      // clear is correct: it drops whatever the queue holds and makes an
      // in-flight `queue_reader` stale.
      final int targetQueueGeneration = _queued?.queueGeneration ?? 0;
      final bool targeted =
          targetQueueGeneration != 0 &&
          _queued?.sourceGeneration == _generation;
      try {
        final int result = _status(
          await _callWorker(
            targeted
                ? LazerWorkerOp.clearQueuedReaderEx
                : LazerWorkerOp.clearQueuedReader,
            <Object?>[
              address,
              if (targeted) targetQueueGeneration,
              generation,
              if (targeted) false,
            ],
          ),
        );
        if (result < 0 && result != lazerAudioErrorState) {
          _faultWorker();
          return;
        }
        if (result == lazerAudioQueueAlreadyAudible) return;
        // The native boundary can win before its asynchronous event reaches
        // Dart. Its reader is now active and must survive until open/stop.
        if (result == lazerAudioQueueAlreadyActive) {
          final bool announced = _mixPresented;
          _mixPresented = false;
          _crossIntoSuccessor(position.inMilliseconds, announce: !announced);
          return;
        }
        if (result == lazerAudioErrorState) {
          // Stale request: the engine acted on nothing, so an installed reader
          // is still being called. Leave it for a transition to confirm away.
          return;
        }
      } catch (error) {
        debugPrint('lazer-audio: clearing the queued source failed: $error');
        return;
      }
    }
    _releaseQueued();
  }

  void _releaseQueued() {
    final _SuccessorBinding? queued = _queued;
    _queued = null;
    queued?.reader.release();
    queued?.entry?.cancelIfUnleased();
  }

  void _confirmSourceTransition(
    int generation, {
    bool retiresGeneration = false,
  }) {
    if (generation > _confirmedSourceGeneration) {
      _confirmedSourceGeneration = generation;
    }
    _releaseDeferredReaders(
      beforeSourceGeneration: retiresGeneration ? generation + 1 : generation,
    );
  }

  /// Whether the engine may still be holding a successor whose retirement this
  /// isolate could not prove. A deferred reader keeps the queue slot occupied
  /// until a source transition confirms the engine moved on.
  bool get _successorSlotUnconfirmed => _deferredReaderRetirements.any(
    (retirement) => retirement.sourceGeneration == _generation,
  );

  void _deferSupersededReader(
    NativeStreamReader reader,
    AudioStreamEntry? entry,
    String url,
    int sourceGeneration,
    int queueGeneration,
  ) {
    if (sourceGeneration < _confirmedSourceGeneration) {
      _retireOrHold(reader);
      entry?.cancelIfUnleased();
      return;
    }
    if (_deferredReaderRetirements.any(
      (retirement) => identical(retirement.reader, reader),
    )) {
      return;
    }
    _deferredReaderRetirements.add(
      _SuccessorBinding(reader, entry, url, sourceGeneration, queueGeneration),
    );
  }

  /// Releases readers whose successful queue_reader was followed by a stop.
  ///
  /// They are only freed after stop or destruction is acknowledged: until then
  /// the native decode path may still hold their callbacks.
  void _releaseDeferredReaders({int? beforeSourceGeneration}) {
    if (_deferredReaderRetirements.isEmpty) return;
    for (
      int index = _deferredReaderRetirements.length - 1;
      index >= 0;
      index--
    ) {
      final retirement = _deferredReaderRetirements[index];
      if (beforeSourceGeneration == null ||
          retirement.sourceGeneration < beforeSourceGeneration) {
        _deferredReaderRetirements.removeAt(index);
        retirement.reader.release();
        retirement.entry?.cancelIfUnleased();
      }
    }
  }

  /// Connects a cache entry to the reader the engine reads it through.
  ///
  /// The only fact the reader needs from the entry is the track's total size: a
  /// demuxer turns a seek's timestamp into a byte offset through it, and the size
  /// arrives with the response headers — after the reader exists.
  void _connectEntry(AudioStreamLease lease, NativeStreamReader reader) {
    final entry = lease.entry;
    lease.bindReader(
      appended: () {
        reader.notifyAppended();
        if (identical(_activeEntry, entry)) _emitBufferChange();
      },
      finished: (bool failed) {
        reader.finish(failed: failed);
        if (identical(_activeEntry, entry)) _emitBufferChange();
      },
      lengthKnown: () {
        final int? total = entry.expectedBytes;
        if (total != null && total > 0) reader.setLength(total);
      },
    );
  }

  /// How long an open waits for the track's size before letting the decoder
  /// start anyway. The size is what a demuxer turns a seek into, so it is worth
  /// a short wait; a server that never announces one must not delay playback.
  static const Duration sourceLengthWait = Duration(seconds: 3);

  /// How long a successor preparation waits for the same fact.
  static const Duration successorLengthWait = Duration(seconds: 5);

  /// Resolves the cache entry for [url], or null for a local file.
  Future<AudioStreamLease?> _cacheLeaseFor(String url) async {
    final Uri? uri = Uri.tryParse(url);
    final String scheme = uri?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      return _cache.acquire(url);
    }
    return null;
  }

  String _localPath(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    return url;
  }

  void _releaseActive({AudioStreamEntry? keepEntry}) {
    _activeReader?.release();
    _activeReader = null;
    if (!identical(_activeEntry, keepEntry)) _activeEntry?.cancelIfUnleased();
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
      // The three conditions and the derived verdict, so the log answers "is this
      // session bit-perfect, and if not, which condition failed" without a UI.
      'dsp_active': info == null ? null : (info.dspActive ? 1 : 0),
      'format_matches_source': info == null
          ? null
          : (info.formatMatchesSource ? 1 : 0),
      'bit_perfect': info?.outputPath.bitPerfect == true ? 1 : 0,
      'engine_claims_bit_perfect': info == null
          ? null
          : (info.bitPerfectActive ? 1 : 0),
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
    if (_disposed) return;
    // Transport events describe the loaded source and are meaningless while a
    // new one is opening. A failure is not: a lost device or a dead decoder
    // during that window used to be dropped, leaving the app "playing" with no
    // output until the next event.
    final bool terminal =
        event == lazerAudioEventEnded ||
        event == lazerAudioEventFailed ||
        event == lazerAudioEventDeviceLost;
    if (!terminal && !_sourceLoaded) return;
    if (terminal) {
      if (event == lazerAudioEventEnded && !_sourceLoaded) return;
      final int? address = _engineAddressOrNull;
      if (address == null) return;
      final Pointer<LazerAudioSnapshot> snapshot = _snapshotBuffer ??=
          calloc<LazerAudioSnapshot>();
      final int expectedState = event == lazerAudioEventEnded
          ? lazerAudioStateStopped
          : lazerAudioStateFailed;
      // NativeCallable.listener delivers callbacks asynchronously. A previous
      // source (or a refused DSD-auto attempt) can report after a new open has
      // already succeeded. Only the current native terminal record may retire
      // that source; use its detail rather than a delayed callback's payload.
      if (_api.snapshot(Pointer<Void>.fromAddress(address), snapshot) !=
              lazerAudioOk ||
          snapshot.ref.state != expectedState ||
          snapshot.ref.terminalEvent != event) {
        return;
      }
      detail = snapshot.ref.terminalDetail;
      positionMillis = snapshot.ref.terminalPositionMillis;
    }
    switch (event) {
      case lazerAudioEventEnded:
        _finishSource();
      case lazerAudioEventTrackChanged:
        // Always announced: the app resolves the crossed-into track from the
        // index it bound to the prepared URL, so its own position is idempotent,
        // and this is the event that lets it prepare the successor *after* the
        // overlap instead of during it.
        _mixPresented = false;
        _crossIntoSuccessor(positionMillis);
      case lazerAudioEventTrackMixStarted:
        _announceMix(positionMillis);
      case lazerAudioEventFailed:
        _reportFailure(
          'playback failed (${_errorName(detail)})',
          _failureKind(detail),
        );
      case lazerAudioEventDeviceLost:
        _reportFailure('the output device was lost', AudioFailureKind.device);
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

  void _reportFailure(String message, AudioFailureKind kind) {
    if (_completionSent) return;
    _completionSent = true;
    _sourceLoaded = false;
    // The callback may arrive while a paused/preloaded source has no AppState
    // playback to stop. Retire its path here as soon as native reports failure.
    // Readers remain owned until stop or destruction confirms their release.
    _publishStreamInfo(null);
    if (!_failures.isClosed) _failures.add(AudioFailure(message, kind));
  }

  /// What an engine error code means for recovery.
  ///
  /// A device error is the one the app can answer by opening the output again
  /// (the endpoint is gone, the source is fine); a source or decode error
  /// describes the stream itself and would repeat on a reload.
  AudioFailureKind _failureKind(int code) => switch (code) {
    lazerAudioErrorDevice => AudioFailureKind.device,
    lazerAudioErrorDecode => AudioFailureKind.decode,
    lazerAudioErrorSource => AudioFailureKind.source,
    _ => AudioFailureKind.unknown,
  };

  /// The engine crossed into the queued successor inside the same output session.
  void _crossIntoSuccessor(int positionMillis, {bool announce = true}) {
    final _SuccessorBinding? successor = _queued;
    if (successor == null) {
      // The boundary was crossed for a successor this isolate did not track (the
      // preparation lost its race and `_settleSupersededReader` already reported
      // it, or the event arrived after a stop). Nothing to swap; the current
      // reader stays owned by `_activeReader`.
      return;
    }
    final NativeStreamReader? previousReader = _activeReader;
    final AudioStreamEntry? previousEntry = _activeEntry;
    _activeReader = successor.reader;
    _activeEntry = successor.entry;
    _queued = null;
    if (announce) _queueIndex++;
    _position = Duration(milliseconds: positionMillis);
    _pendingSeek = null;
    _completionSent = false;
    _sourceLoaded = true;
    _mixPresented = false;
    previousReader?.release();
    previousEntry?.cancelIfUnleased();
    _emitBufferChange();
    _publishStreamInfo(readStreamInfo());
    if (announce && !_advanced.isClosed) _advanced.add(_queueIndex);
    // A multi-URL queue can already hold the following track; the app otherwise
    // appends one in reaction to this event.
    final String? next = _pendingUrls.firstOrNull;
    if (next != null) {
      unawaited(_prepareSuccessor(next));
    }
  }

  void _announceMix(int outgoingPositionMillis) {
    if (_mixPresented || _queued == null) return;
    _mixPresented = true;
    _mixStartOutgoingMillis = outgoingPositionMillis;
    _position = Duration.zero;
    _queueIndex++;
    if (!_advanced.isClosed) _advanced.add(_queueIndex);
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

class _SuccessorBinding {
  const _SuccessorBinding(
    this.reader,
    this.entry,
    this.url,
    this.sourceGeneration,
    this.queueGeneration,
  );

  final NativeStreamReader reader;
  final AudioStreamEntry? entry;
  final String url;
  final int sourceGeneration;
  final int queueGeneration;
}
