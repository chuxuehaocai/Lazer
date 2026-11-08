import '../utils/media_requests.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_engine.dart';

/// The portable transition plan used when the full offline AutoMix renderer is
/// unavailable.  The Python project uses beat grids and stem analysis to find
/// a handoff; this plan keeps the same important invariant (an overlap with a
/// musical length) without requiring a Python runtime, model download, FFmpeg,
/// or Rubber Band on the target device.
class AutoMixTransitionPlanner {
  const AutoMixTransitionPlanner({this.maximum = const Duration(seconds: 8)});

  final Duration maximum;

  Duration duration({Duration? outgoing, Duration? incoming}) {
    final int maxMs = maximum.inMilliseconds.clamp(500, 30 * 1000);
    int upper = maxMs;
    if (outgoing != null && outgoing > Duration.zero) {
      upper = math.min(
        upper,
        math.max(100, (outgoing.inMilliseconds * .20).round()),
      );
    }
    if (incoming != null && incoming > Duration.zero) {
      upper = math.min(
        upper,
        math.max(100, (incoming.inMilliseconds * .25).round()),
      );
    }
    // Very short tracks are capped by their own duration, so the transition
    // can never consume the whole outgoing or incoming source.
    return Duration(milliseconds: upper);
  }

  /// Equal-power curves preserve perceived loudness when two tracks overlap.
  (double, double) gains(double progress) {
    final double p = progress.clamp(0, 1).toDouble();
    return (math.cos(p * math.pi / 2), math.sin(p * math.pi / 2));
  }
}

/// Two independently prepared decoders keep the next track playing while the
/// current track fades. The queue advances only after the overlap finishes.
class AutoMixAudioEngine
    implements
        AudioEngine,
        AutoMixConfigurableAudioEngine,
        BufferedAudioEngine,
        StartupBufferReportingAudioEngine,
        BufferChangeReportingAudioEngine,
        SeekBoundaryReportingAudioEngine,
        QueueAudioEngine,
        QueuedSourceReportingAudioEngine,
        MixPresentingAudioEngine,
        FocusAwareAudioEngine,
        SessionPreparingAudioEngine,
        FailureReportingAudioEngine {
  AutoMixAudioEngine({
    bool enabled = true,
    AutoMixTransitionPlanner planner = const AutoMixTransitionPlanner(),
    AudioPlayer Function()? playerFactory,
    this.fallbackNotice,
  }) {
    _planner = planner;
    _enabled = enabled;
    final factory = playerFactory ?? _defaultPlayer;
    _primary = factory();
    _secondary = factory();
    _active = _primary;
    _watch(_primary);
    _watch(_secondary);
    _clock = Timer.periodic(const Duration(milliseconds: 40), (_) => _tick());
  }

  static AudioPlayer _defaultPlayer() => AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
    androidApplyAudioAttributes: false,
  );

  late final AutoMixTransitionPlanner _planner;
  final String? fallbackNotice;
  late final AudioPlayer _primary;
  late final AudioPlayer _secondary;
  late AudioPlayer _active;
  AudioPlayer? _incoming;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  late final Timer _clock;
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<int> _advanced = StreamController<int>.broadcast();
  final StreamController<AudioFailure> _failures =
      StreamController<AudioFailure>.broadcast();
  final StreamController<void> _bufferChanges =
      StreamController<void>.broadcast();

  @override
  Future<bool> Function()? activateSession;
  @override
  Future<void> Function()? prepareSession;

  late bool _enabled;
  bool _disposed = false;
  bool _sourceLoaded = false;
  bool _activeCompleted = false;
  bool _playing = false;
  bool _transitioning = false;
  bool _presentedIncoming = false;
  bool _tickPending = false;
  Duration _transitionLength = Duration.zero;
  Duration _incomingStartPosition = Duration.zero;
  int _generation = 0;
  int _playGeneration = 0;
  int _queueId = 0;
  int _currentIndex = 0;
  List<String> _queueUrls = <String>[];
  String? _activeUrl;
  double _volume = 1;
  Future<void> _operations = Future<void>.value();

  bool get enabled => _enabled;

  Future<void> setEnabled(bool value) => setAutoMixEnabled(value);

  @override
  Future<void> setAutoMixEnabled(bool value) {
    _enabled = value;
    return _serialize(() async {
      if (_disposed) return;
      // Keep the prepared successor: AppState still owns its queue index.
      // Turning off overlap must not discard an already accepted append.
      if (!_enabled) await _resetOverlap();
    });
  }

  void _watch(AudioPlayer player) {
    _subscriptions.add(
      player.processingStateStream.listen((ProcessingState state) {
        if (state == ProcessingState.completed) _completedPlayer(player);
      }),
    );
    _subscriptions.add(
      player.bufferedPositionStream.listen((Duration _) {
        if (!_bufferChanges.isClosed) _bufferChanges.add(null);
      }),
    );
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final Future<T> result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _load(AudioPlayer player, String url) async {
    final Uri uri = Uri.parse(url);
    if (uri.scheme == 'file') {
      await player.setFilePath(uri.toFilePath());
    } else {
      await player.setUrl(url, headers: MediaRequestRules.headers(url));
    }
  }

  Future<void> applyAudioAttributes(AndroidAudioAttributes attributes) async {
    await Future.wait(<Future<void>>[
      _primary.setAndroidAudioAttributes(attributes),
      _secondary.setAndroidAudioAttributes(attributes),
    ]);
  }

  @override
  bool get active => _sourceLoaded;
  AudioPlayer get _presentedPlayer =>
      _presentedIncoming && _incoming != null ? _incoming! : _active;

  @override
  Duration get position => _presentedPlayer.position;
  @override
  Duration? get duration => _presentedPlayer.duration;
  @override
  Duration get bufferedPosition => _presentedPlayer.bufferedPosition;
  @override
  Duration? get startupBufferedPosition => _presentedPlayer.bufferedPosition;
  @override
  bool get seekIsLimitedByBuffer {
    final String scheme =
        Uri.tryParse(_activeUrl ?? '')?.scheme.toLowerCase() ?? '';
    return scheme == 'http' || scheme == 'https';
  }

  /// The URL the second decoder is preparing, or null when there is none.
  @override
  String? get queuedSourceUrl {
    if (_incoming == null || _currentIndex + 1 >= _queueUrls.length) {
      return null;
    }
    return _queueUrls[_currentIndex + 1];
  }

  /// Whether the incoming decoder is the one being heard right now.
  @override
  bool get mixPresented => _presentedIncoming && _incoming != null;

  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<int> get indexStream => _advanced.stream;
  @override
  Stream<void> get bufferChanges => _bufferChanges.stream;
  @override
  Stream<AudioFailure> get failures => _failures.stream;
  @override
  AudioFailure? get pendingFailure => fallbackNotice == null
      ? null
      : AudioFailure(fallbackNotice!, AudioFailureKind.unknown);

  @override
  Future<void> setUrl(String url) async {
    await setQueue(<String>[url]);
  }

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) {
    final int generation = ++_generation;
    ++_playGeneration;
    final int id = ++_queueId;
    _sourceLoaded = false;
    _playing = false;
    return _serialize(() async {
      if (_disposed || generation != _generation) return id;
      _transitioning = false;
      _presentedIncoming = false;
      _activeCompleted = false;
      _incoming = null;
      _activeUrl = null;
      _queueUrls = List<String>.of(urls);
      await Future.wait(<Future<void>>[_primary.stop(), _secondary.stop()]);
      if (_disposed || generation != _generation || urls.isEmpty) return id;
      _active = _primary;
      _currentIndex = startIndex.clamp(0, urls.length - 1).toInt();
      await _load(_active, urls[_currentIndex]);
      if (_disposed || generation != _generation) return id;
      _activeUrl = urls[_currentIndex];
      _sourceLoaded = true;
      await _active.setVolume(_volume);
      if (_currentIndex + 1 < _queueUrls.length) await _prepareNext(generation);
      return id;
    });
  }

  Future<bool> _prepareNext(int generation) async {
    if (_disposed || generation != _generation || !_sourceLoaded) return false;
    if (_incoming != null) return true;
    if (_currentIndex + 1 >= _queueUrls.length) return false;
    final AudioPlayer target = _active == _primary ? _secondary : _primary;
    try {
      await target.stop();
      // Mute before loading as well as before playing, so a reused decoder can
      // never briefly expose the previous track's gain.
      await target.setVolume(0);
      await _load(target, _queueUrls[_currentIndex + 1]);
      if (_disposed || generation != _generation) return false;
      _incoming = target;
      return true;
    } catch (_) {
      // Preparing a successor is speculative. Its failure must not report a
      // terminal error for the healthy track that is currently playing.
      return false;
    }
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) {
    final int generation = _generation;
    return _serialize(() async {
      if (_disposed ||
          generation != _generation ||
          queueId != _queueId ||
          !_sourceLoaded) {
        return false;
      }
      // While an overlap is running, the second decoder already holds the
      // track the UI is presenting. There is no free decoder for the track
      // after it yet: claiming this append as prepared would make AppState
      // treat the announced track as the successor and send a manual skip to
      // the wrong decoder. Report the miss so AppState reloads the requested
      // track through its normal path; the queue slot is intentionally not
      // retained, because the two-player engine cannot use it now.
      if (_presentedIncoming) return false;
      if (_incoming != null) {
        // Already prepared for exactly this successor.
        return _currentIndex + 1 < _queueUrls.length &&
            _queueUrls[_currentIndex + 1] == url;
      }
      _queueUrls.add(url);
      if (await _prepareNext(generation)) return true;
      if (generation == _generation && queueId == _queueId) {
        _queueUrls.removeLast();
      }
      return false;
    });
  }

  @override
  Future<bool> playQueuedNext() {
    final int generation = _generation;
    return _serialize(() async {
      if (_disposed ||
          generation != _generation ||
          _incoming == null ||
          // The incoming track is already audible as the presented track.
          // Promoting it again would keep playing the same song while the
          // caller advances to the following one.
          _presentedIncoming) {
        return false;
      }
      await _promoteIncoming(automatic: false);
      return true;
    });
  }

  // just_audio's play Future completes when playback stops, not when it starts.
  // Observe it without awaiting it in transport or transition operations.
  void _startPlayer(AudioPlayer player, int generation) {
    unawaited(
      player.play().catchError((Object error, StackTrace stack) {
        if (_disposed || generation != _generation) return;
        if (player == _incoming) {
          unawaited(
            _serialize(() async {
              if (player != _incoming || generation != _generation) return;
              _transitioning = false;
              _incoming = null;
              await _active.setVolume(_volume);
              await player.stop();
            }),
          );
        } else if (player == _active && _sourceLoaded) {
          _playing = false;
          if (!_failures.isClosed) {
            _failures.add(
              AudioFailure('$error\n$stack', AudioFailureKind.unknown),
            );
          }
        }
      }),
    );
  }

  @override
  Future<void> play() async {
    if (!_sourceLoaded || _disposed) return;
    final int generation = _generation;
    final int playGeneration = ++_playGeneration;
    if (prepareSession != null) await prepareSession!();
    if (generation != _generation ||
        playGeneration != _playGeneration ||
        _disposed) {
      return;
    }
    if (activateSession != null && !await activateSession!()) {
      if (generation != _generation ||
          playGeneration != _playGeneration ||
          _disposed) {
        return;
      }
      throw StateError('Audio session activation denied');
    }
    if (generation != _generation ||
        playGeneration != _playGeneration ||
        _disposed) {
      return;
    }
    _playing = true;
    if (_activeCompleted) {
      await _serialize(() async {
        if (_disposed || generation != _generation || !_playing) return;
        await _finishActive();
      });
      return;
    }
    _startPlayer(_active, generation);
    if (_transitioning && _incoming != null) {
      _startPlayer(_incoming!, generation);
    }
  }

  @override
  Future<void> pause() async {
    ++_playGeneration;
    _playing = false;
    await Future.wait(<Future<void>>[_primary.pause(), _secondary.pause()]);
  }

  Future<void> _resetOverlap() async {
    if (_presentedIncoming && _incoming != null) {
      await _promoteIncoming(automatic: false);
      return;
    }
    final bool wasTransitioning = _transitioning;
    _transitioning = false;
    _presentedIncoming = false;
    _transitionLength = Duration.zero;
    if (_sourceLoaded) await _active.setVolume(_volume);
    final AudioPlayer? incoming = _incoming;
    if (wasTransitioning && incoming != null) {
      await incoming.pause();
      await incoming.seek(Duration.zero);
      await incoming.setVolume(0);
    }
  }

  @override
  Future<void> seek(Duration value) {
    final int generation = _generation;
    return _serialize(() async {
      if (_disposed || generation != _generation) return;
      await _resetOverlap();
      await _active.seek(value);
      if (_disposed || generation != _generation) return;
      // Completion keeps the decoder/source prepared for repeat-one. A seek
      // revives that source; stop clears its URL and must stay stopped.
      if (_activeUrl != null) {
        _sourceLoaded = true;
        _activeCompleted = false;
      }
    });
  }

  double get _transitionProgress {
    final AudioPlayer? incoming = _incoming;
    if (!_transitioning ||
        incoming == null ||
        _transitionLength <= Duration.zero) {
      return 0;
    }
    // Decoder progress freezes during pause and buffering. Wall-clock time
    // would fade the healthy track to silence while its successor is stalled.
    return ((incoming.position - _incomingStartPosition).inMicroseconds /
            _transitionLength.inMicroseconds)
        .clamp(0, 1)
        .toDouble();
  }

  Future<void> _applyGains() async {
    final AudioPlayer? incoming = _incoming;
    if (!_sourceLoaded) return;
    if (!_transitioning || incoming == null) {
      await _active.setVolume(_volume);
      return;
    }
    final (double outgoingGain, double incomingGain) = _planner.gains(
      _transitionProgress,
    );
    await Future.wait(<Future<void>>[
      _active.setVolume(_volume * outgoingGain),
      incoming.setVolume(_volume * incomingGain),
    ]);
  }

  @override
  Future<void> setVolume(double volume) {
    _volume = volume.clamp(0, 1).toDouble();
    return _serialize(_applyGains);
  }

  @override
  Future<void> stop() {
    ++_generation;
    ++_playGeneration;
    _sourceLoaded = false;
    _activeCompleted = false;
    _playing = false;
    _transitioning = false;
    _incoming = null;
    _activeUrl = null;
    _queueUrls = <String>[];
    return _serialize(() async {
      await Future.wait(<Future<void>>[_primary.stop(), _secondary.stop()]);
    });
  }

  void _completedPlayer(AudioPlayer player) {
    if (_disposed || !_sourceLoaded || player != _active) return;
    _activeCompleted = true;
    final int generation = _generation;
    unawaited(
      _serialize(() async {
        if (_disposed ||
            generation != _generation ||
            !_sourceLoaded ||
            player != _active) {
          return;
        }
        if (_playing) await _finishActive();
      }),
    );
  }

  Future<void> _finishActive() async {
    if (_incoming != null) {
      await _promoteIncoming(automatic: true);
    } else {
      _sourceLoaded = false;
      _playing = false;
      if (!_completed.isClosed) _completed.add(null);
    }
  }

  void _tick() {
    if (_disposed ||
        _tickPending ||
        !_sourceLoaded ||
        !_playing ||
        !_enabled ||
        _incoming == null) {
      return;
    }
    _tickPending = true;
    final int generation = _generation;
    unawaited(
      _serialize(() async {
            if (_disposed ||
                generation != _generation ||
                !_sourceLoaded ||
                !_playing ||
                !_enabled ||
                _incoming == null) {
              return;
            }
            if (!_transitioning) {
              final Duration? total = _active.duration;
              if (total == null || total <= Duration.zero) return;
              final Duration overlap = _planner.duration(
                outgoing: total,
                incoming: _incoming!.duration,
              );
              final Duration remaining = total - _active.position;
              if (remaining > overlap || remaining <= Duration.zero) return;
              final Uri? nextUri = Uri.tryParse(_queueUrls[_currentIndex + 1]);
              final bool localSource =
                  nextUri?.scheme == 'file' || nextUri?.scheme == 'asset';
              // Preserve the healthy outgoing track at full gain until the
              // successor has enough decoded/downloaded audio for the entire
              // overlap. A ready decoder with a tiny buffer can still stall.
              if (!localSource &&
                  _incoming!.bufferedPosition - _incoming!.position <
                      remaining) {
                return;
              }
              _transitionLength = remaining;
              _incomingStartPosition = _incoming!.position;
              _transitioning = true;
              _announceIncoming();
              await _incoming!.setVolume(0);
              if (!_playing || generation != _generation) return;
              _startPlayer(_incoming!, generation);
            }
            await _applyGains();
            if (_transitionProgress >= 1) {
              await _promoteIncoming(automatic: true);
            }
          })
          .catchError((Object error, StackTrace stack) {
            if (!_disposed &&
                generation == _generation &&
                !_failures.isClosed) {
              _failures.add(
                AudioFailure('$error\n$stack', AudioFailureKind.unknown),
              );
            }
          })
          .whenComplete(() {
            _tickPending = false;
          }),
    );
  }

  Future<void> _promoteIncoming({required bool automatic}) async {
    final AudioPlayer? incoming = _incoming;
    if (incoming == null || _disposed) return;
    if (automatic && !_playing) return;
    final int generation = _generation;
    final AudioPlayer outgoing = _active;
    await incoming.setVolume(_volume);
    if (_disposed || generation != _generation || (automatic && !_playing)) {
      return;
    }
    _incoming = null;
    _transitioning = false;
    _activeCompleted = false;
    _active = incoming;
    final bool announced = _presentedIncoming;
    if (!announced) {
      ++_currentIndex;
      _activeUrl = _queueUrls[_currentIndex];
    }
    _presentedIncoming = false;
    if (_playing && !incoming.playing) _startPlayer(incoming, generation);
    // All getters now refer to the incoming track before the index event, so
    // listeners read its real position instead of resetting a running track.
    if (automatic && !announced && !_advanced.isClosed) {
      _advanced.add(_currentIndex);
    }
    if (!_bufferChanges.isClosed) _bufferChanges.add(null);
    await outgoing.stop();
    if (_currentIndex + 1 < _queueUrls.length) await _prepareNext(generation);
  }

  void _announceIncoming() {
    if (_presentedIncoming ||
        _incoming == null ||
        _currentIndex + 1 >= _queueUrls.length) {
      return;
    }
    _presentedIncoming = true;
    _currentIndex++;
    _activeUrl = _queueUrls[_currentIndex];
    if (!_advanced.isClosed) _advanced.add(_currentIndex);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    ++_playGeneration;
    _sourceLoaded = false;
    _clock.cancel();
    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(
      _operations.whenComplete(() async {
        await Future.wait(<Future<void>>[
          _primary.dispose(),
          _secondary.dispose(),
        ]);
      }),
    );
    unawaited(_completed.close());
    unawaited(_advanced.close());
    unawaited(_failures.close());
    unawaited(_bufferChanges.close());
  }
}
