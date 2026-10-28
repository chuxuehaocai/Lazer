import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../state/app_state.dart';
import 'audio_engine.dart';

/// Owns optional OS audio focus, without replacing the playback engine.
class PlaybackSession {
  PlaybackSession(
    this.state,
    this.engine, {
    Future<AudioSession> Function()? sessionFactory,
  }) : _sessionFactory = sessionFactory ?? (() => AudioSession.instance),
       _independent = state.independentPlayback {
    if (engine is FocusAwareAudioEngine) {
      (engine as FocusAwareAudioEngine).activateSession = _activate;
    }
    state.addListener(_changed);
  }

  final AppState state;
  final AudioEngine engine;
  final Future<AudioSession> Function() _sessionFactory;
  Future<void> get settled => _operations;
  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _interruptions;
  StreamSubscription<void>? _noisy;
  bool _closed = false;
  bool _independent = false;
  bool _resume = false;
  String? _interruptedTrack;
  int _generation = 0;
  Future<void> _operations = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _changed() {
    if (_closed || _independent == state.independentPlayback) return;
    _independent = state.independentPlayback;
    ++_generation;
    _resume = false;
    if (_independent) {
      unawaited(_interruptions?.cancel());
      unawaited(_noisy?.cancel());
      _interruptions = null;
      _noisy = null;
      final session = _session;
      if (session != null) {
        unawaited(
          _serialize(() async {
            await session.setActive(false);
          }).catchError((Object error) {
            debugPrint('Audio focus release failed: $error');
          }),
        );
      }
    } else if (state.playing) {
      unawaited(
        _activate()
            .then((active) {
              if (!active && !_closed && !state.independentPlayback) {
                state.pause();
              }
            })
            .catchError((Object error) {
              debugPrint('Audio focus activation failed: $error');
              if (!_closed && !state.independentPlayback) state.pause();
            }),
      );
    }
  }

  Future<AudioSession> _configure() async {
    final session = await _sessionFactory();
    if (_closed || state.independentPlayback) return session;
    await session.configure(const AudioSessionConfiguration.music());
    if (!_closed &&
        !state.independentPlayback &&
        defaultTargetPlatform == TargetPlatform.android) {
      final attributes = session.androidAudioAttributes;
      // Only the just_audio path owns Android audio attributes; the native engine
      // has its own output backend and ignores them.
      if (attributes != null && engine is JustAudioEngine) {
        await (engine as JustAudioEngine).applyAudioAttributes(attributes);
      }
    }
    _session = session;
    return session;
  }

  Future<bool> _activate() async {
    if (_closed) return false;
    if (state.independentPlayback) return true;
    final generation = _generation;
    return _serialize(() => _activateCurrent(generation));
  }

  Future<bool> _activateCurrent(int generation) async {
    if (_closed) return false;
    if (state.independentPlayback) return true;
    if (generation != _generation) return _activateCurrent(_generation);
    final session = _session ?? await _configure();
    if (_closed || generation != _generation || state.independentPlayback) {
      if (!_closed && !state.independentPlayback) {
        return _activateCurrent(_generation);
      }
      return !_closed && state.independentPlayback;
    }
    _interruptions ??= session.interruptionEventStream.listen((event) {
      if (generation == _generation) _interrupted(event);
    });
    _noisy ??= session.becomingNoisyEventStream.listen((_) {
      if (_closed || state.independentPlayback || generation != _generation) {
        return;
      }
      _resume = false;
      state.pause();
    });
    final active = await session.setActive(true);
    if (_closed || state.independentPlayback || generation != _generation) {
      await session.setActive(false);
      if (!_closed && !state.independentPlayback) {
        return _activateCurrent(_generation);
      }
      return !_closed && state.independentPlayback;
    }
    return active;
  }

  void _interrupted(AudioInterruptionEvent event) {
    if (_closed || state.independentPlayback) return;
    if (event.begin) {
      if (event.type == AudioInterruptionType.duck) return;
      _resume = state.playing;
      _interruptedTrack = state.current?.id;
      state.pause();
    } else {
      final resume =
          _resume &&
          event.type == AudioInterruptionType.pause &&
          _interruptedTrack == state.current?.id;
      _resume = false;
      if (resume) state.play();
    }
  }

  void close() {
    _closed = true;
    ++_generation;
    state.removeListener(_changed);
    if (engine is FocusAwareAudioEngine) {
      (engine as FocusAwareAudioEngine).activateSession = () async => false;
    }
    unawaited(_interruptions?.cancel());
    unawaited(_noisy?.cancel());
    final session = _session;
    if (session != null) {
      unawaited(
        _serialize(() async {
          await session.setActive(false);
        }).catchError((Object _) {}),
      );
    }
  }
}
