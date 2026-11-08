import '../utils/media_requests.dart';
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Optional engine capability: how far the current source has buffered.
///
/// Kept separate from [AudioEngine] so engines that cannot answer (and the
/// test doubles that only need transport) stay valid. The now-playing seek
/// rail paints this as the muted lead-in behind the played fraction.
abstract interface class BufferedAudioEngine {
  Duration get bufferedPosition;
}

/// Distinguishes an empty startup buffer from an unmeasurable network stream.
/// Unknown duration or HTTP length must not be treated as zero downloaded audio.
abstract interface class StartupBufferReportingAudioEngine {
  Duration? get startupBufferedPosition;
}

/// Optional notifications when an engine's buffered position changes.
///
/// This is separate from playback ticks so a paused track can still paint cache
/// progress as bytes continue arriving.
abstract interface class BufferChangeReportingAudioEngine {
  Stream<void> get bufferChanges;
}

/// Optional capability for streams that cannot seek past their buffered data.
abstract interface class SeekBoundaryReportingAudioEngine {
  bool get seekIsLimitedByBuffer;
}

/// Optional capability: an engine that knows which positions it can reach.
///
/// Engines whose seek parks a decoder on the source (the native engine reads
/// through a growing file) can only reach what the download has landed, and they
/// are the ones that answer this. A player that simply hands the seek to its
/// platform does not implement it: there the rail's buffer limit is a UI policy,
/// not a rule the engine enforces.
abstract interface class SeekRangeReportingAudioEngine {
  /// Whether the current source can be seeked to [position] right now.
  ///
  /// True for local files and fully downloaded streams; for a growing stream it
  /// follows how much of the track has landed.
  bool canSeekTo(Duration position);
}

/// Optional capability: what a network source's download is doing right now.
///
/// A CDN that never sends `Content-Length` (chunked transfer, a proxied CDN, an
/// HLS-style segmenter) makes "how far ahead are we" unanswerable: the fraction
/// is unknown, not zero. That distinction is what this surface carries:
///
///   * [streamedBytes] is always real — the downloader's byte counter — so a
///     caller can tell "the download has not started" (0 bytes: playing now
///     gives the decoder an empty file to block on) from "the download cannot be
///     measured" (bytes are landing but there is no total to divide by).
///   * [streamFailed] is the download the engine is feeding the decoder from
///     having ended in failure. The engine reports that as a decode failure too,
///     but a caller watching a screen-position watchdog should see it without
///     waiting for the terminal event.
///   * [streamStalled] means no byte has landed for long enough that the reader
///     is about to give up, which is the state a slow-but-alive CDN produces.
///
/// Engines without this surface (and the test doubles that only need transport)
/// keep the plain [AudioEngine] behaviour: [AudioEngine] itself never requires it.
abstract interface class StreamingBufferHealthAudioEngine {
  /// Bytes of the current network source that have landed on disk.
  ///
  /// Null when the current source is not a network source.
  int? get streamedBytes;

  /// Whether the current download has failed (as opposed to still running or
  /// having finished cleanly).
  bool get streamFailed;

  /// Whether no byte of the current download has landed for long enough that
  /// playback is stalled rather than merely slow.
  bool get streamStalled;

  /// Restarts the current network source, resuming the cache file where it
  /// stopped. Returns false when there is nothing to restart (not a network
  /// source, or no cache entry behind the current source).
  bool restartStream();
}

/// Optional engine capability: a queue the platform keeps decoding across.
///
/// [AudioEngine.setUrl] replaces the source, which tears the decoder down and
/// rebuilds the stream: between two tracks that is an audible gap. An engine
/// that can hold the following source in the same platform queue crosses the
/// boundary while the decoder is still running, so album tracks run into each
/// other the way the master does.
///
/// The capability is separate from [AudioEngine] on purpose: engines and test
/// doubles that only implement transport keep working, and [AppState] falls
/// back to the completion-driven path when the engine lacks it.
abstract interface class QueueAudioEngine {
  /// Replaces the loaded queue with [urls] and positions it on [startIndex].
  ///
  /// Returns an identifier for the queue that was installed; [appendToQueue]
  /// takes it back so an append racing a reload cannot land in the new queue.
  Future<int> setQueue(List<String> urls, {int startIndex = 0});

  /// Appends [url] to the queue installed under [queueId].
  ///
  /// Returns false when that queue is no longer the active one, so the caller
  /// knows the append did not happen and must not expect the hand-off.
  Future<bool> appendToQueue(int queueId, String url);

  /// Moves to the next item of the loaded queue without reloading it.
  ///
  /// Returns `false` when the platform queue no longer has a next item. The
  /// caller can then load the requested track as a fresh source instead of
  /// leaving the UI ahead of the audio.
  Future<bool> playQueuedNext();

  /// Fires when the platform crosses into the next item on its own — the
  /// gapless hand-off. Seeks, loads and appends are not reported.
  Stream<int> get indexStream;
}

/// Reports the item the engine holds as the successor of the playing source.
///
/// The app binds a queue index to the URL it appended; reading that URL back
/// when the engine crosses is what proves it crossed into the song the queue
/// scripted rather than a successor a racing preparation replaced, and what tells
/// the app whether a hand-off can still arrive at all.
abstract interface class QueuedSourceReportingAudioEngine {
  /// The URL the engine holds as its next item, or null when it holds none.
  String? get queuedSourceUrl;
}

/// Reports an overlap the engine is currently playing.
///
/// AutoMix is audible before the hand-off, and the engine can roll the overlap
/// back — a seek cancels it and returns to the outgoing song. The app has to go
/// back with it, or its queue position ends up a song ahead of what is heard.
abstract interface class MixPresentingAudioEngine {
  /// Whether the engine is overlapping the prepared next item right now.
  bool get mixPresented;
}

/// Queue preparation can block the same worker that accepts play commands.
/// These engines acknowledge play before starting a successor preparation.
abstract interface class SerialQueueAudioEngine implements QueueAudioEngine {}

/// Mixes a prepared successor into the current source before it finishes.
/// This changes the decoding/mixing policy without changing the output engine.
abstract interface class AutoMixConfigurableAudioEngine {
  Future<void> setAutoMixEnabled(bool enabled);
}

/// Why a source failed after it was loaded.
///
/// Only [device] is actionable by reopening: the output session is gone (the
/// platform reclaimed the endpoint, another application took it over, or the
/// audio route changed), and the same track plays again on a fresh open at the
/// position it reached. Every other kind describes the source itself, which
/// would decode identically a second time.
enum AudioFailureKind {
  /// The output device was lost; reopening it is the recovery.
  device,

  /// The source could not be read or demuxed.
  source,

  /// The source decoded badly or not at all.
  decode,

  /// A failure whose cause the engine cannot classify.
  unknown,
}

/// A failure reported by an engine after a source was loaded.
class AudioFailure {
  const AudioFailure(this.message, this.kind);

  /// User-facing text (device lost, decode error).
  final String message;

  /// What kind of loss this is, so the app can pick a recovery.
  final AudioFailureKind kind;

  @override
  String toString() => message;
}

/// Optional engine capability: failures that happen *after* a source was loaded.
///
/// `just_audio` surfaces those through its own player streams, but an engine
/// backed by a native callback has no throw site to hand them to. [AppState]
/// listens when the engine offers it and otherwise keeps the load-time handling.
///
/// The capability also carries the *startup* downgrade: when the native engine
/// could not start, the app runs on `just_audio` and the reason is reported
/// through this interface rather than only written to the log, so "not on the
/// HiFi path" is a fact the UI can state.
abstract interface class FailureReportingAudioEngine {
  /// User-facing text and kind for a terminal failure (device lost, decode error).
  Stream<AudioFailure> get failures;

  /// A reason already known before any listener could attach — the fallback this
  /// launch started with. Null when the session came up on the native engine.
  ///
  /// Separate from [failures] because the downgrade happens while the engine is
  /// being constructed, before the app subscribes: a broadcast event sent then
  /// would be dropped.
  AudioFailure? get pendingFailure;
}

/// Optional engine capability: the app installs its audio-focus policy here.
///
/// `PlaybackSession` owns OS focus once per app; engines that can ask before
/// starting playback implement this so the first track does not begin into an
/// interrupted or ducked stream. Test doubles and engines without focus handling
/// simply do not implement it.
abstract interface class FocusAwareAudioEngine {
  Future<bool> Function()? activateSession;
}

/// A backend that holds the output device itself, so an interruption has to give
/// it back rather than park it.
///
/// A shared-mode Android stream parked in PAUSED keeps owning the endpoint, and
/// the platform hands that endpoint to whoever took the output — which is how a
/// resume ends up starting a stream that no longer exists. Losing focus on such a
/// backend therefore closes the device (the source is opened again on resume,
/// at the position it reached), while a backend that owns its session from
/// inside the player keeps the plain pause/resume behaviour.
abstract interface class InterruptionYieldingAudioEngine {}

/// An engine that can refuse a software volume change.
///
/// Direct output (bit-perfect, DoP or native DSD) owns the level: the stream
/// must stay untouched, so a request to lower the software volume is rejected.
/// [appliedVolume] reports the level the engine really runs, which is what the
/// UI has to show instead of a slider that moves while the audio does not.
abstract interface class VolumeConstraintAudioEngine {
  double get appliedVolume;

  /// Why the last level could not be applied, or null when it was.
  String? get volumeNotice;
}

/// A backend that must know the OS session category before opening output.
///
/// Preparing a paused source must not request audio focus. In particular,
/// iOS RemoteIO chooses its route during open, before the first play call.
abstract interface class SessionPreparingAudioEngine {
  Future<void> Function()? prepareSession;
}

/// Playback surface used for stream URLs returned by the gateway.
abstract class AudioEngine {
  /// Whether a source is currently loaded.
  bool get active;

  Duration get position;
  Duration? get duration;

  Future<void> setUrl(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> stop();

  /// Fires once each time the current source finishes playing.
  Stream<void> get completed;

  void dispose();
}

/// just_audio-backed engine used by the real app.
class JustAudioEngine
    implements
        AudioEngine,
        BufferedAudioEngine,
        BufferChangeReportingAudioEngine,
        SeekBoundaryReportingAudioEngine,
        QueueAudioEngine,
        QueuedSourceReportingAudioEngine,
        FocusAwareAudioEngine,
        FailureReportingAudioEngine {
  JustAudioEngine({
    AudioPlayer? player,
    this.activateSession,
    this.fallbackNotice,
  }) : _player =
           player ??
           AudioPlayer(
             handleInterruptions: false,
             handleAudioSessionActivation: false,
             androidApplyAudioAttributes: false,
           ) {
    _completionSubscription = _player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) _completionSent = false;
      if (state == ProcessingState.completed) _emitCompletion();
    });
  }

  /// Optional application-owned focus policy; absent in independent playback.
  @override
  Future<bool> Function()? activateSession;

  /// Why this launch runs on `just_audio` instead of the native engine, when
  /// that was already decided before the app could subscribe.
  ///
  /// `just_audio` has no failure callback of its own to route here — its errors
  /// arrive through the player's streams — so this is normally the only value
  /// [pendingFailure] ever holds. A future fallback that happens *during*
  /// playback (the native engine losing its device) can be pushed through
  /// [reportFailure] and reaches the app through [failures].
  final String? fallbackNotice;

  final StreamController<AudioFailure> _failures =
      StreamController<AudioFailure>.broadcast();

  @override
  Stream<AudioFailure> get failures => _failures.stream;

  @override
  AudioFailure? get pendingFailure => fallbackNotice == null
      ? null
      : AudioFailure(fallbackNotice!, AudioFailureKind.unknown);

  /// Reports a failure that happened after start-up on the fallback engine.
  ///
  /// Returns false once the engine is disposed, so a late caller can tell the
  /// report went nowhere instead of assuming the UI saw it.
  bool reportFailure(
    String message, {
    AudioFailureKind kind = AudioFailureKind.unknown,
  }) {
    if (_failures.isClosed) return false;
    _failures.add(AudioFailure(message, kind));
    return true;
  }

  Future<void> applyAudioAttributes(AndroidAudioAttributes attributes) =>
      _player.setAndroidAudioAttributes(attributes);

  final AudioPlayer _player;
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<int> _advanced = StreamController<int>.broadcast();
  late final StreamSubscription<ProcessingState> _completionSubscription;

  /// Index events are only needed once a queue is loaded; subscribing lazily
  /// keeps the plain [setUrl] path (and players that only implement it) as it
  /// was.
  StreamSubscription<int?>? _indexSubscription;
  bool _hadSource = false;
  bool _completionSent = false;
  int _generation = 0;
  int _playGeneration = 0;

  /// Platform queue and the identifier the app takes back when appending.
  ConcatenatingAudioSource? _queue;
  List<String> _queueUrls = <String>[];
  String? _currentUrl;
  int _queueId = 0;

  /// Index the engine itself asked the platform for, so a platform-side index
  /// change can be told apart from our own seeks and loads.
  int? _commandedIndex;

  /// Source mutations are serialized: a prefetch append racing a track change
  /// must never append to a queue that was already replaced.
  Future<void> _operations = Future<void>.value();

  void _emitCompletion() {
    if (!_hadSource || _completionSent || _completed.isClosed) return;
    _completionSent = true;
    _completed.add(null);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final Future<T> result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _onPlatformIndex(int? index) {
    if (index == null) return;
    if (index >= 0 && index < _queueUrls.length) {
      _currentUrl = _queueUrls[index];
    }
    if (!_hadSource || _advanced.isClosed) return;
    if (index == _commandedIndex) return;
    // The platform moved on without being asked: the gapless hand-off.
    _commandedIndex = index;
    _advanced.add(index);
  }

  @override
  bool get active => _hadSource;

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  Duration get bufferedPosition => _player.bufferedPosition;

  @override
  bool get seekIsLimitedByBuffer {
    final String? scheme = Uri.tryParse(
      _currentUrl ?? '',
    )?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  @override
  String? get queuedSourceUrl {
    final int? index = _player.currentIndex;
    if (index == null || index + 1 >= _queueUrls.length) return null;
    return _queueUrls[index + 1];
  }

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<void> get bufferChanges {
    try {
      return _player.bufferedPositionStream.map<void>((Duration _) {});
    } on NoSuchMethodError {
      // Small injected players used by embedders may expose a position but no
      // buffered-position stream.
      return const Stream<void>.empty();
    }
  }

  @override
  Stream<int> get indexStream => _advanced.stream;

  @override
  Future<void> setUrl(String url) {
    final generation = ++_generation;
    _hadSource = false;
    _completionSent = false;
    _queue = null;
    _queueUrls = <String>[url];
    _currentUrl = url;
    _commandedIndex = null;
    // The single-source fallback has to take its turn with the queue loads:
    // otherwise a `setQueue` that failed while another track was already
    // loading let two platform loads run at once, which media_kit turns into
    // a native crash.
    return _serialize(() async {
      // A newer load or a stop superseded this one before its turn; opening it
      // now would tear down whatever the newer call is opening.
      if (generation != _generation) return;
      final uri = Uri.parse(url);
      if (uri.scheme == 'file') {
        await _player.setFilePath(uri.toFilePath());
      } else {
        await _player.setUrl(url, headers: MediaRequestRules.headers(url));
      }
      if (generation != _generation) return;
      _commandedIndex = 0;
      _hadSource = true;
      if (_player.processingState == ProcessingState.completed) {
        _emitCompletion();
      }
    });
  }

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    final generation = ++_generation;
    _hadSource = false;
    _completionSent = false;
    _commandedIndex = null;
    final int queueId = ++_queueId;
    _queue = null;
    _queueUrls = List<String>.of(urls);
    _currentUrl = urls.isEmpty
        ? null
        : urls[startIndex.clamp(0, urls.length - 1).toInt()];
    return _serialize(() async {
      // Rapid next/previous presses queue several of these; only the newest
      // should reach the platform. The older ones return their queue id so the
      // caller's generation check rejects them without another native load.
      if (generation != _generation) return queueId;
      _indexSubscription ??= _player.currentIndexStream.listen(
        _onPlatformIndex,
      );
      final ConcatenatingAudioSource source = ConcatenatingAudioSource(
        useLazyPreparation: false,
        children: <AudioSource>[
          for (final String url in urls)
            AudioSource.uri(
              Uri.parse(url),
              headers: MediaRequestRules.headers(url),
            ),
        ],
      );
      await _player.setAudioSource(source, initialIndex: startIndex);
      if (generation != _generation) return queueId;
      _queue = source;
      _commandedIndex = startIndex;
      _hadSource = true;
      if (_player.processingState == ProcessingState.completed) {
        _emitCompletion();
      }
      return queueId;
    });
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) {
    return _serialize(() async {
      final ConcatenatingAudioSource? queue = _queue;
      if (queue == null || queueId != _queueId) return false;
      await queue.add(
        AudioSource.uri(
          Uri.parse(url),
          headers: MediaRequestRules.headers(url),
        ),
      );
      if (queueId != _queueId) return false;
      _queueUrls.add(url);
      final int? currentIndex = _player.currentIndex;
      if (currentIndex != null && currentIndex < _queueUrls.length) {
        _currentUrl = _queueUrls[currentIndex];
      }
      return true;
    });
  }

  @override
  Future<bool> playQueuedNext() {
    return _serialize(() async {
      final ConcatenatingAudioSource? queue = _queue;
      final int? index = _player.currentIndex;
      if (queue == null || index == null) return false;
      if (index + 1 >= queue.children.length) return false;
      _commandedIndex = index + 1;
      await _player.seek(Duration.zero, index: index + 1);
      if (index + 1 < _queueUrls.length) {
        _currentUrl = _queueUrls[index + 1];
      }
      return true;
    });
  }

  @override
  Future<void> play() async {
    final generation = _generation;
    final playGeneration = ++_playGeneration;
    if (activateSession != null && !await activateSession!()) {
      if (playGeneration != _playGeneration) return;
      throw StateError('Audio session activation denied');
    }
    if (generation != _generation ||
        playGeneration != _playGeneration ||
        !_hadSource) {
      return;
    }
    await _player.play();
  }

  @override
  Future<void> pause() {
    ++_playGeneration;
    return _player.pause();
  }

  @override
  Future<void> seek(Duration position) {
    _commandedIndex = _player.currentIndex;
    return _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0, 1));

  @override
  Future<void> stop() {
    ++_playGeneration;
    ++_generation;
    _hadSource = false;
    _completionSent = false;
    _queue = null;
    _queueUrls = <String>[];
    _currentUrl = null;
    _commandedIndex = null;
    // `AudioPlayer.stop()` deactivates the platform, which for media_kit means
    // releasing the native mpv player. Ordered behind the source mutations so
    // it can never release a player that is still opening a stream — the
    // native crash a rapid switch burst (or a failed track) used to cause.
    return _serialize(() => _player.stop());
  }

  @override
  void dispose() {
    ++_generation;
    ++_playGeneration;
    _hadSource = false;
    _queueUrls = <String>[];
    _currentUrl = null;
    _completionSubscription.cancel();
    _indexSubscription?.cancel();
    _completed.close();
    _advanced.close();
    _failures.close();
    _player.dispose();
  }
}
