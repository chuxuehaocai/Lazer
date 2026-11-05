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
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import '../../storage/app_storage.dart';

import '../audio_engine.dart';
import 'audio_path_log.dart';
import 'audio_stream_cache.dart';
import 'engine_metrics.dart';
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
        StreamingBufferHealthAudioEngine {
  NativeAudioEngine._(
    this._api,
    this._bridge,
    this._worker,
    this._events,
    this._cache,
    this._deviceSettings,
  );

  @visibleForTesting
  factory NativeAudioEngine.forTesting({
    required LazerAudioApi api,
    required LazerAudioBridgeApi bridge,
    required LazerAudioWorker worker,
    required AudioStreamCache cache,
  }) {
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
  final StreamController<AudioFailure> _failures =
      StreamController<AudioFailure>.broadcast();
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
  bool _mixPresented = false;
  int _mixStartOutgoingMillis = 0;
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
    _sourceLoaded = false;
    _completionSent = false;
    unawaited(
      _serialize(() async {
        await stop();
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
    _sourceLoaded = false;
    _mixPresented = false;
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
    _mixPresented = false;
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
    if (_queuedReader != null || _queuedUrl != null) {
      await _clearQueued();
      if (queueId != _queueId || !_sourceLoaded || _disposed) return false;
    }
    // Deliberately not part of the `_operations` chain: preparing the successor
    // reads its first bytes, and a skip pressed meanwhile must not wait for that.
    // A preparation that loses the race releases its own reader (see
    // `_prepareSuccessor`), so nothing leaks.
    unawaited(_prepareSuccessor(url));
    return true;
  }

  /// The URL this engine has prepared as its successor, or null when it holds
  /// none.
  ///
  /// The app binds a queue index to the URL it appended and reads it back when
  /// the engine crosses, which is what makes "the mixed-in song is the one the
  /// queue scripted" checkable.
  @override
  String? get queuedSourceUrl => _queuedUrl;

  /// Whether the successor is already audible inside an overlap.
  @override
  bool get mixPresented => _mixPresented;

  @override
  Future<bool> playQueuedNext() async {
    final bool fromPending = _queuedUrl == null;
    final pending = _pendingUrls;
    final String? next = _queuedUrl ?? _pendingUrls.firstOrNull;
    if (next == null) return false;
    final int generation = ++_generation;
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
    // A seek cancels an overlap that is playing: the engine drops the incoming
    // side and keeps the successor queued, so the outgoing song is what is heard
    // again and the position is back on its timeline. The app notices the same
    // thing through [mixPresented] before it asks for the seek.
    _mixPresented = false;
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

  bool get supportsAutoMix => _api.setAutoMix != null;

  /// Configure before opening a source: AutoMix uses two PCM decoders feeding
  /// the existing output device, including when that device is exclusive.
  /// An existing source needs reopening to renegotiate its PCM format.
  @override
  Future<void> setAutoMixEnabled(bool enabled) async {
    if (!supportsAutoMix) {
      if (enabled) {
        throw UnsupportedError('This audio engine has no overlap mixer.');
      }
      return;
    }
    final int? address = _engineAddressOrNull;
    if (address == null) return;
    final int status = _status(
      await _worker.call(LazerWorkerOp.setAutoMix, <Object?>[
        address,
        enabled ? 8000 : 0,
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
    List<int> stageOrder = const <int>[],
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
      // Empty means the engine's default order; see `HifiSettings.dspStageOrder`.
      stageOrder,
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
    _mixPresented = false;
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
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // RemoteIO's open reads the session's actual route and sample clock.
      // Configure its category before that open, while leaving focus activation
      // to play(). Preloading must not acquire focus or reject an existing source.
      await prepareSession?.call();
      if (generation != _generation || _disposed) return;
    }
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
        // The size arrives with the response headers. A demuxer needs it to turn
        // a seek's timestamp into a byte offset, so the reader is created with it
        // when it is known by now.
        final int? length = await entry.expectedLengthWithin(sourceLengthWait);
        if (generation != _generation || _disposed) return;
        reader = NativeStreamReader.create(
          bridge,
          path: entry.file.path,
          expectedBytes: length ?? entry.expectedBytes,
        );
        if (reader == null) {
          throw StateError('the reader bridge rejected ${entry.file.path}');
        }
        final NativeStreamReader sourceReader = reader;
        final AudioStreamEntry sourceEntry = entry;
        _connectEntry(sourceEntry, sourceReader);
        entry.bindReader(
          appended: () {
            sourceReader.notifyAppended();
            if (identical(_activeEntry, sourceEntry)) _emitBufferChange();
          },
          finished: (bool failed) {
            sourceReader.finish(failed: failed);
            if (identical(_activeEntry, sourceEntry)) _emitBufferChange();
          },
        );
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
      _releaseActive(keepEntry: entry);
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
      final String path = entry?.file.path ?? _localPath(url);
      final int? expectedBytes = entry == null
          ? await File(path).length()
          // A successor is decoded ahead of its audible boundary, so waiting for
          // the announced size costs nothing the mix needs.
          : await entry.expectedLengthWithin(successorLengthWait) ??
                entry.expectedBytes;
      if (generation != _queueGeneration || !_sourceLoaded || _disposed) return;
      // Repeat-one and adjacent copies of the same URL share one growing
      // download. It currently has one reader callback pair: rebinding it here
      // would strand the audible reader, and retiring that reader would cancel
      // the successor's download too. Keep this URL pending and reopen it on
      // completion (or manual skip), after the old reader has finished.
      if (entry != null && identical(entry, _activeEntry)) {
        // A different successor may already be prepared (for example before
        // repeat-one was selected). Drop it while keeping this pending repeat.
        await _clearQueued();
        return;
      }
      reader = NativeStreamReader.create(
        bridge,
        path: path,
        expectedBytes: expectedBytes,
      );
      if (reader == null) return;
      // The cache download can finish after this local is transferred to
      // `_queuedReader` and set to null below. Capture the reader itself so the
      // completion callback still signals the bridge instead of throwing from
      // the cache's unawaited download future.
      final NativeStreamReader queuedReader = reader;
      final AudioStreamEntry? queuedEntry = entry;
      if (queuedEntry != null) _connectEntry(queuedEntry, queuedReader);
      entry?.bindReader(
        appended: () {
          queuedReader.notifyAppended();
          if (identical(_activeEntry, queuedEntry)) _emitBufferChange();
        },
        finished: (bool failed) {
          queuedReader.finish(failed: failed);
          if (identical(_activeEntry, queuedEntry)) _emitBufferChange();
        },
      );
      if (entry == null) queuedReader.finish();
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
      // appendToQueue keeps the URL available while preparation is pending so
      // a manual skip can still open it. Once prepared, the reader owns it;
      // leaving it pending would prepare the same song again at its boundary,
      // racing the app's next prefetch and rebinding the active cache reader.
      if (_pendingUrls.firstOrNull == url) {
        _pendingUrls = _pendingUrls.skip(1).toList();
      }
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
        final int result = _status(
          await _worker.call(LazerWorkerOp.clearQueuedReader, <Object?>[
            address,
            generation,
          ]),
        );
        // The native boundary can win before its asynchronous event reaches
        // Dart. Its reader is now active and must survive until open/stop.
        if (result == lazerAudioQueueAlreadyActive) {
          final bool announced = _mixPresented;
          _mixPresented = false;
          _crossIntoSuccessor(position.inMilliseconds, announce: !announced);
          return;
        }
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

  /// Connects a cache entry to the reader the engine reads it through.
  ///
  /// The only fact the reader needs from the entry is the track's total size: a
  /// demuxer turns a seek's timestamp into a byte offset through it, and the size
  /// arrives with the response headers — after the reader exists.
  void _connectEntry(AudioStreamEntry entry, NativeStreamReader reader) {
    entry.onLengthKnown = () {
      final int? total = entry.expectedBytes;
      if (total != null && total > 0) reader.setLength(total);
    };
  }

  /// How long an open waits for the track's size before letting the decoder
  /// start anyway. The size is what a demuxer turns a seek into, so it is worth
  /// a short wait; a server that never announces one must not delay playback.
  static const Duration sourceLengthWait = Duration(seconds: 3);

  /// How long a successor preparation waits for the same fact.
  static const Duration successorLengthWait = Duration(seconds: 5);

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

  void _releaseActive({AudioStreamEntry? keepEntry}) {
    _activeReader?.release();
    _activeReader = null;
    if (!identical(_activeEntry, keepEntry)) _activeEntry?.cancel();
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
    if (_disposed || !_sourceLoaded) return;
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
    if (announce) _queueIndex++;
    _position = Duration(milliseconds: positionMillis);
    _pendingSeek = null;
    _completionSent = false;
    _sourceLoaded = true;
    _mixPresented = false;
    previousReader?.release();
    previousEntry?.cancel();
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
    if (_mixPresented || _queuedReader == null) return;
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
