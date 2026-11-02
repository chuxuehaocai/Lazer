import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
// Inspect the registry owned by our existing just_audio_media_kit dependency.
// Re-registering that plugin discards its table of active main-player handles.
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

const stillAliveAudioAsset = 'assets/easter_eggs/still_alive/sa1.mp3';

/// Playback used by the terminal page. It owns no system media metadata.
abstract interface class StillAlivePlayback implements Listenable {
  bool get ready;
  bool get playing;
  Duration get position;
  Duration? get duration;
  String? get error;
  Future<void> load();
  Future<void> play();
  Future<void> pause();
  Future<void> restart();
  Future<void> setVolume(double volume);
  Future<void> close();
  void dispose();
}

enum StillAliveAudioStatus { idle, loading, buffering, ready, completed }

/// An authoritative clock report from the decoder, rather than a UI timer.
class StillAliveAudioSnapshot {
  const StillAliveAudioSnapshot({
    required this.position,
    required this.playing,
    required this.status,
    this.duration,
  });
  final Duration position;
  final Duration? duration;
  final bool playing;
  final StillAliveAudioStatus status;
}

/// Injectable so lifecycle and transport races can be tested without speakers.
abstract interface class StillAliveAudioBackend {
  Stream<StillAliveAudioSnapshot> get snapshots;
  Stream<Object> get errors;
  Future<Duration?> load(String asset);

  /// Acknowledges the start request; does not await the entire song ending.
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

/// A separate player for the easter egg. Main playback is paused by its page;
/// leaving this player never resumes the main queue automatically.
///
/// Decoder reports anchor a monotonic clock. Callers may read [position] at
/// their animation cadence without creating a second periodic audio timer.
class StillAliveAudio extends ChangeNotifier implements StillAlivePlayback {
  StillAliveAudio({
    StillAliveAudioBackend Function()? backendFactory,
    Duration Function()? clock,
    double volume = 1,
  }) : _backendFactory = backendFactory ?? createStillAliveAudioBackend {
    final stopwatch = Stopwatch()..start();
    _clock = clock ?? (() => stopwatch.elapsed);
    _volume = _normalizeVolume(volume);
  }

  final StillAliveAudioBackend Function() _backendFactory;
  late final Duration Function() _clock;
  StillAliveAudioBackend? _backend;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void>? _loading;
  Future<void>? _closing;
  bool _closed = false;
  bool _notifierDisposed = false;
  bool _ready = false;
  bool _playing = false;
  bool _advancing = false;
  bool _completed = false;
  bool _requestedPlay = false;
  bool _positionFrozen = false;
  int? _restartFence;
  bool _seekingStart = false;
  int _intent = 0;
  Duration _position = Duration.zero;
  Duration _reportedAt = Duration.zero;
  Duration? _duration;
  String? _error;
  double _volume = 1;
  Future<void> _volumeTail = Future<void>.value();

  static double _normalizeVolume(double volume) =>
      volume.isFinite ? volume.clamp(0.0, 1.0) : 1;

  @override
  bool get ready => _ready && !_closed;
  @override
  bool get playing => _playing && !_closed;
  @override
  Duration? get duration => _duration;
  @override
  String? get error => _error;

  @override
  Duration get position {
    var value = _position;
    if (_advancing && !_closed) {
      final elapsed = _clock() - _reportedAt;
      if (elapsed > Duration.zero) value += elapsed;
    }
    if (value < Duration.zero) return Duration.zero;
    final end = _duration;
    return end != null && value > end ? end : value;
  }

  void _notify() {
    if (!_closed && !_notifierDisposed) notifyListeners();
  }

  void _freeze() {
    _position = position;
    _reportedAt = _clock();
    _advancing = false;
  }

  void _report(StillAliveAudioSnapshot report) {
    if (_closed) return;
    _duration = report.duration ?? _duration;
    if (_restartFence != null) {
      // Seeking resets the position before every backend resets its completed
      // status. Even a completed report at zero belongs to the previous pass.
      if (_seekingStart || report.status == StillAliveAudioStatus.completed) {
        return;
      }
      if (_restartFence == _intent &&
          _requestedPlay &&
          report.playing &&
          report.status == StillAliveAudioStatus.ready) {
        _restartFence = null;
      }
    }
    // Native output may deliver its final position tens of milliseconds after
    // pause has returned. Keep the explicit pause boundary stable; a later
    // user play/restart (or a fresh load) reopens decoder clock updates.
    if (!_positionFrozen) {
      _position = report.position;
      _reportedAt = _clock();
      _completed = report.status == StillAliveAudioStatus.completed;
      if (_completed) {
        _requestedPlay = false;
        _position = _duration ?? report.position;
      }
    }
    _playing = report.playing && _requestedPlay && !_completed;
    _advancing = _playing && report.status == StillAliveAudioStatus.ready;
    // A late focus/decoder report cannot undo an explicit background pause.
    if (report.playing && !_requestedPlay && !_completed) {
      // Avoid reentering a synchronous backend stream while it is reporting.
      scheduleMicrotask(() {
        if (!_closed && !_requestedPlay) unawaited(_pauseBackend());
      });
    }
    _notify();
  }

  void _failure(Object failure) {
    if (_closed) return;
    _freeze();
    _positionFrozen = true;
    _restartFence = null;
    _requestedPlay = false;
    _playing = false;
    _ready = false;
    _error = failure.toString();
    unawaited(_pauseBackend());
    _notify();
  }

  Future<void> _pauseBackend() async {
    try {
      await _backend?.pause();
    } catch (failure) {
      // An existing decode/activation error is the useful diagnostic; a
      // subsequent pause failure must not replace it or escape disposal.
      if (!_closed && _error == null) {
        _error = failure.toString();
        _ready = false;
        _notify();
      }
    }
  }

  @override
  Future<void> load() {
    if (_closed || _ready) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    _error = null;
    _positionFrozen = false;
    _notify();
    try {
      final backend = _backend ??= _backendFactory();
      if (_subscriptions.isEmpty) {
        _subscriptions
          ..add(backend.snapshots.listen(_report, onError: _failure))
          ..add(backend.errors.listen(_failure));
      }
      final duration = await backend.load(stillAliveAudioAsset);
      if (_closed) return;
      await _applyVolume(backend);
      if (_closed) return;
      _duration = duration ?? _duration;
      _ready = _error == null;
      _notify();
    } catch (failure) {
      _failure(failure);
    }
  }

  @override
  Future<void> play() async {
    if (_closed) return;
    final replay = _completed || _restartFence != null;
    final intent = ++_intent;
    _positionFrozen = false;
    _requestedPlay = true;
    if (replay) _prepareRestart(intent);
    await load();
    if (_closed || !_ready || !_requestedPlay || intent != _intent) return;
    try {
      if (replay) {
        if (!await _seekToStart(intent)) return;
      }
      await _backend!.play();
      if (_closed || !_requestedPlay) {
        await _pauseBackend();
      }
    } catch (failure) {
      _failure(failure);
    }
  }

  @override
  Future<void> pause() async {
    if (_closed) return;
    ++_intent;
    _restartFence = null;
    _requestedPlay = false;
    _freeze();
    _positionFrozen = true;
    _playing = false;
    _notify();
    await _pauseBackend();
  }

  @override
  Future<void> restart() async {
    if (_closed) return;
    final intent = ++_intent;
    _positionFrozen = false;
    _requestedPlay = true;
    _prepareRestart(intent);
    await load();
    if (_closed || !_ready || !_requestedPlay || intent != _intent) return;
    try {
      if (!await _seekToStart(intent)) return;
      await _backend!.play();
      if (_closed || !_requestedPlay) {
        await _pauseBackend();
      }
    } catch (failure) {
      _failure(failure);
    }
  }

  void _prepareRestart(int intent) {
    _restartFence = intent;
    _seekingStart = true;
    _completed = false;
    _playing = false;
    _advancing = false;
    _position = Duration.zero;
    _reportedAt = _clock();
    _notify();
  }

  Future<bool> _seekToStart(int intent) async {
    _prepareRestart(intent);
    try {
      await _backend!.seek(Duration.zero);
    } finally {
      if (_restartFence == intent) _seekingStart = false;
    }
    return !_closed && _requestedPlay && intent == _intent;
  }

  Future<void> _applyVolume(StillAliveAudioBackend backend) {
    final operation = _volumeTail.then((_) async {
      double applied;
      do {
        if (_closed) return;
        applied = _volume;
        await backend.setVolume(applied);
      } while (!_closed && applied != _volume);
    });
    // Preserve command ordering after a platform error so retry can proceed.
    _volumeTail = operation.catchError((Object _) {});
    return operation;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_closed) return;
    _volume = _normalizeVolume(volume);
    final backend = _backend;
    // Before load, keep the main volume without creating a platform player.
    if (backend == null) return;
    try {
      await _applyVolume(backend);
    } catch (failure) {
      _failure(failure);
    }
  }

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _freeze();
    _closed = true;
    _ready = false;
    _playing = false;
    _requestedPlay = false;
    ++_intent;
    return _closing = _release();
  }

  Future<void> _release() async {
    // Pause immediately, even if asset loading or listener cancellation is
    // still in flight. All subsequent reports are already ignored.
    final silence = _pauseBackend();
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } catch (_) {
        // A broken stream must not prevent the decoder being released.
      }
    }
    _subscriptions.clear();
    await silence;
    final backend = _backend;
    if (backend != null) {
      try {
        await backend.stop();
      } catch (_) {
        // dispose is mandatory even when output has already failed.
      } finally {
        try {
          await backend.dispose();
        } catch (_) {
          // Widget.dispose cannot surface an asynchronous platform teardown
          // failure. The player has already received both pause and stop.
        }
        _backend = null;
      }
    }
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    unawaited(close());
    _notifierDisposed = true;
    super.dispose();
  }
}

/// Uses the real plugin for desktop validation as well as the terminal page.
@visibleForTesting
StillAliveAudioBackend createStillAliveAudioBackend() {
  ensureStillAliveDesktopAudioBackend();
  return _JustAudioBackend();
}

/// Installs the existing desktop plugin only when no player registry exists.
/// Native main playback can reach this route without initializing just_audio.
@visibleForTesting
void ensureStillAliveDesktopAudioBackend() {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux) &&
      JustAudioPlatform.instance is! JustAudioMediaKit) {
    // The main native engine never needs just_audio, so this can be the first
    // platform player opened in the process. Android/iOS keep their own plugin.
    JustAudioMediaKit.ensureInitialized();
  }
}

class _JustAudioBackend implements StillAliveAudioBackend {
  _JustAudioBackend()
    : _player = audio.AudioPlayer(
        handleInterruptions: true,
        handleAudioSessionActivation: true,
      ) {
    _subscriptions
      ..add(_player.playerStateStream.listen((_) => _report(), onError: _error))
      ..add(_player.positionStream.listen((_) => _report(), onError: _error))
      ..add(_player.durationStream.listen((_) => _report(), onError: _error))
      ..add(_player.playbackEventStream.listen((_) {}, onError: _error));
  }

  final audio.AudioPlayer _player;
  final _snapshots = StreamController<StillAliveAudioSnapshot>.broadcast(
    sync: true,
  );
  final _errors = StreamController<Object>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;
  int _playGeneration = 0;

  @override
  Stream<StillAliveAudioSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<Object> get errors => _errors.stream;

  void _report() {
    if (_disposed) return;
    _snapshots.add(
      StillAliveAudioSnapshot(
        position: _player.position,
        duration: _player.duration,
        playing: _player.playing,
        status: switch (_player.processingState) {
          audio.ProcessingState.idle => StillAliveAudioStatus.idle,
          audio.ProcessingState.loading => StillAliveAudioStatus.loading,
          audio.ProcessingState.buffering => StillAliveAudioStatus.buffering,
          audio.ProcessingState.ready => StillAliveAudioStatus.ready,
          audio.ProcessingState.completed => StillAliveAudioStatus.completed,
        },
      ),
    );
  }

  void _error(Object failure) {
    if (!_disposed) _errors.add(failure);
  }

  @override
  Future<Duration?> load(String asset) => _player.setAsset(asset);
  @override
  Future<void> play() async {
    final generation = ++_playGeneration;
    // just_audio silently reverts its playing flag if focus is denied. Check
    // explicitly so the page can offer a retry rather than claim sound works.
    final session = await AudioSession.instance;
    if (_disposed || generation != _playGeneration) return;
    if (!await session.setActive(true)) {
      if (_disposed || generation != _playGeneration) return;
      throw StateError('Audio output could not acquire audio focus.');
    }
    if (_disposed || generation != _playGeneration) return;
    // just_audio's future lasts until pause/completion. The page needs to
    // remain responsive now, with late failures delivered through [errors].
    unawaited(_player.play().catchError(_error));
  }

  @override
  Future<void> pause() {
    ++_playGeneration;
    return _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    final source = _player.audioSource;
    if (_player.processingState == audio.ProcessingState.completed &&
        source != null) {
      // media_kit can retain completed after seeking away from EOF. Reopen the
      // same asset while paused so the next play starts a fresh pass.
      await _player.pause();
      if (_disposed) return;
      await _player.setAudioSource(source, initialPosition: position);
      return;
    }
    await _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> stop() {
    ++_playGeneration;
    return _player.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_playGeneration;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _player.dispose();
    } finally {
      await _snapshots.close();
      await _errors.close();
    }
  }
}
