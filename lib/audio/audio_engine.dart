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
  /// User-facing text for a terminal failure (device lost, decode error).
  Stream<String> get failures;

  /// A reason already known before any listener could attach — the fallback this
  /// launch started with. Null when the session came up on the native engine.
  ///
  /// Separate from [failures] because the downgrade happens while the engine is
  /// being constructed, before the app subscribes: a broadcast event sent then
  /// would be dropped.
  String? get pendingFailure;
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

  final StreamController<String> _failures = StreamController<String>.broadcast();

  @override
  Stream<String> get failures => _failures.stream;

  @override
  String? get pendingFailure => fallbackNotice;

  /// Reports a failure that happened after start-up on the fallback engine.
  ///
  /// Returns false once the engine is disposed, so a late caller can tell the
  /// report went nowhere instead of assuming the UI saw it.
  bool reportFailure(String message) {
    if (_failures.isClosed) return false;
    _failures.add(message);
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
        await _player.setUrl(url);
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
          for (final String url in urls) AudioSource.uri(Uri.parse(url)),
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
      await queue.add(AudioSource.uri(Uri.parse(url)));
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
