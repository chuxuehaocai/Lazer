import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'media_artwork_cache.dart';
import 'windows_media_platform.dart';
import 'linux_media_platform.dart';
import 'switchable_media_platform.dart';

typedef MediaArtworkResolver = Future<Uri?> Function(String? url);

Future<LazerMediaHandler> initializeSystemMedia(AppState state) async {
  return AudioService.init<LazerMediaHandler>(
    builder: () => LazerMediaHandler(state, enabled: false),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.naominet.lazer.audio',
      androidNotificationChannelName: 'Lazer',
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidStopForegroundOnPause: false,
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
  );
}

/// Initializes AudioService once, only when system integration is requested.
class SystemMediaController {
  SystemMediaController(
    this.state, {
    Future<LazerMediaHandler> Function()? initialize,
    Future<void> Function(bool)? togglePlatform,
  }) {
    if (initialize != null) {
      _initialize = initialize;
      _togglePlatform = togglePlatform ?? (_) async {};
    } else {
      AudioServicePlatform platform = AudioServicePlatform.instance;
      Future<void> Function(bool)? toggleNative;
      if (Platform.isWindows) {
        final windows = WindowsMediaPlatform();
        platform = windows;
        toggleNative = windows.setEnabled;
      } else if (Platform.isLinux) {
        final linux = LinuxMediaPlatform();
        platform = linux;
        toggleNative = linux.setEnabled;
      }
      final gate = SwitchableMediaPlatform(
        platform,
        toggleNative: toggleNative,
      );
      _initialize = () {
        AudioServicePlatform.instance = gate;
        return initializeSystemMedia(state);
      };
      _togglePlatform = gate.setEnabled;
    }
    state.addListener(_changed);
    _changed();
  }

  final AppState state;
  late final Future<LazerMediaHandler> Function() _initialize;
  late final Future<void> Function(bool) _togglePlatform;
  Future<LazerMediaHandler>? _initialization;
  LazerMediaHandler? _handler;
  bool? _enabled;
  bool _closed = false;
  int _generation = 0;
  Future<void> _pending = Future<void>.value();
  Future<void> get settled => _pending;

  void _changed() {
    final enabled = !state.independentPlayback;
    if (_closed || _enabled == enabled) return;
    _enabled = enabled;
    final generation = ++_generation;
    if (!enabled) _handler?.setEnabled(false);
    _pending = _pending.then((_) => _apply(enabled, generation)).catchError((
      Object error,
    ) {
      debugPrint('System media integration failed: $error');
    });
  }

  Future<void> _apply(bool enabled, int generation) async {
    if (_closed || generation != _generation) return;
    if (!enabled && _initialization == null) return;
    final handler = await (_initialization ??= _initialize());
    _handler = handler;
    if (_closed || generation != _generation) {
      if (_closed || state.independentPlayback) {
        handler.setEnabled(false);
        await _togglePlatform(false);
        if (_closed) handler.close();
      }
      return;
    }
    await _togglePlatform(enabled);
    if (_closed || generation != _generation) return;
    handler.setEnabled(enabled);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    ++_generation;
    state.removeListener(_changed);
    _handler?.close();
    if (_initialization != null) {
      _pending = _pending
          .then((_) => _initialization!)
          .then((handler) async {
            handler.close();
            await _togglePlatform(false);
          })
          .catchError((Object error) {
            debugPrint('System media cleanup failed: $error');
          });
    }
  }
}

/// The OS controls command the existing AppState, so UI and remote commands
/// share queue, repeat/shuffle, lyric loading and playback error behavior.
class LazerMediaHandler extends BaseAudioHandler {
  LazerMediaHandler(
    this.state, {
    MediaArtworkResolver? artwork,
    this._enabled = true,
  }) : _artwork = artwork ?? MediaArtworkCache().resolve {
    state.addListener(_stateChanged);
    _stateChanged();
    if (_enabled) _startClock();
  }
  final AppState state;
  final MediaArtworkResolver _artwork;
  Timer? _clock;
  bool _enabled;
  bool get _acceptCommands =>
      !_closed && _enabled && !state.independentPlayback;

  void _startClock() {
    _clock?.cancel();
    // Play/pause/seek already publish through [_stateChanged]; this clock only
    // refreshes the interpolated position, so a slow beat is enough and keeps
    // the platform channel off the playback hot path.
    _clock = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _publishPlayback(),
    );
  }

  void setEnabled(bool enabled) {
    if (_closed || _enabled == enabled) return;
    _enabled = enabled;
    ++_artGeneration;
    _published = null;
    _lyricLine = null;
    if (!enabled) {
      _clock?.cancel();
      playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.idle,
          playing: false,
        ),
      );
      mediaItem.add(null);
      queue.add(const []);
    } else {
      _lastQueueRevision = -1;
      _track = null;
      _stateChanged();
      _startClock();
    }
  }

  int _lastQueueRevision = -1;
  Track? _track;
  int _artGeneration = 0;
  bool _closed = false;
  bool _stopped = false;

  /// The item the platform currently holds, kept so the lyric line and the
  /// artwork can update one field without rebuilding the others.
  MediaItem? _published;

  /// The lyric line the published item carries, so the once-a-second clock
  /// only touches the platform channel when the line actually changed.
  String? _lyricLine;

  /// The current track as a system media item.
  ///
  /// [lyric] is the line being sung. Neither Android's MediaMetadata nor iOS's
  /// MPNowPlayingInfoCenter has a lyrics key — the media notification, the
  /// lock screen and the Dynamic Island all draw their second line from the
  /// *artist* slot — so that is where the line has to travel. The
  /// `display*` trio is set alongside it because Android 12 and older render
  /// the notification the app itself posts, which reads those fields, and a
  /// subtitle without a display title is ignored there.
  static MediaItem _item(Track track, {String? lyric}) => MediaItem(
    id: track.id,
    title: track.title,
    artist: lyric ?? track.artist,
    album: track.album,
    duration: track.duration,
    displayTitle: lyric == null ? null : track.title,
    displaySubtitle: lyric,
    displayDescription: lyric == null ? null : track.artist,
  );

  /// The lyric line the controls should show, or null to keep the artist.
  ///
  /// Mobile only. On a phone the notification and the lock screen are the
  /// primary surface for the song, which is what makes a lyric worth putting
  /// there. The desktop controls are read by other applications too — MPRIS
  /// feeds media applets and chat presences — and their flyouts sit next to an
  /// app that can show the whole lyric sheet anyway, so they keep the artist.
  String? _currentLyric() {
    if (!state.systemMediaLyrics) return null;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return null;
    }
    final String? line = state.currentLyricLine?.text.trim();
    return line == null || line.isEmpty ? null : line;
  }

  void _stateChanged() {
    if (_closed) return;
    if (state.independentPlayback) {
      setEnabled(false);
      return;
    }
    if (!_enabled) return;
    if (state.playing) _stopped = false;
    if (_lastQueueRevision != state.queueRevision) {
      final tracks = state.queue;
      _lastQueueRevision = state.queueRevision;
      // Queue entries keep the plain artist: a controller listing the queue —
      // Android Auto, CarPlay — wants the songs, not the line being sung.
      queue.add(tracks.map(_item).toList());
    }
    final current = state.current;
    if (!identical(current, _track)) {
      _track = current;
      final generation = ++_artGeneration;
      _lyricLine = _currentLyric();
      final item = current == null ? null : _item(current, lyric: _lyricLine);
      _published = item;
      mediaItem.add(item);
      if (current != null) {
        unawaited(
          _artwork(current.coverUrl).then((uri) {
            if (_acceptCommands &&
                generation == _artGeneration &&
                uri != null) {
              _published = item!.copyWith(artUri: uri);
              mediaItem.add(_published);
            }
          }),
        );
      }
    }
    _publishPlayback();
  }

  /// Moves the second line on as the song does.
  ///
  /// Driven by the playback clock rather than by state reports: the app's
  /// playback ticks travel on their own notifier, so a line change is only
  /// visible here once a second. A lyric line lasts several seconds, and the
  /// platform is called at most once per line.
  void _publishLyricLine() {
    if (!_acceptCommands) return;
    final MediaItem? item = _published;
    final Track? track = state.current;
    if (item == null || track == null || !identical(track, _track)) return;
    final String? line = _currentLyric();
    if (line == _lyricLine) return;
    _lyricLine = line;
    _published = item.copyWith(
      artist: line ?? track.artist,
      displayTitle: line == null ? null : track.title,
      displaySubtitle: line,
      displayDescription: line == null ? null : track.artist,
    );
    mediaItem.add(_published);
  }

  void _publishPlayback() {
    if (!_acceptCommands) return;
    _publishLyricLine();
    final track = state.current;
    final active = track != null && !_stopped;
    playbackState.add(
      PlaybackState(
        // These are track commands on iOS: never expose the podcast +/-30s pair.
        controls: active
            ? [
                MediaControl.skipToPrevious,
                state.playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext,
              ]
            : const [],
        androidCompactActionIndices: active ? const [0, 1, 2] : const [],
        systemActions: active
            ? const {MediaAction.seek, MediaAction.playPause}
            : const {},
        processingState: !active
            ? AudioProcessingState.idle
            : state.playbackError != null
            ? AudioProcessingState.error
            : state.playing && !state.audioReady
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: state.playing,
        updatePosition: state.precisePosition,
        bufferedPosition: state.precisePosition,
        queueIndex: active ? state.queueIndex : null,
        repeatMode: switch (state.repeat) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: state.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        errorCode: state.playbackError == null ? null : 1,
        errorMessage: state.playbackError,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (_acceptCommands) state.play();
  }

  @override
  Future<void> pause() async {
    if (_acceptCommands) state.pause();
  }

  @override
  Future<void> skipToNext() async {
    if (_acceptCommands) state.next();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_acceptCommands) state.previous();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_acceptCommands) state.playTrackAt(index);
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_acceptCommands) return;
    final duration = state.current?.duration.inMicroseconds ?? 0;
    if (duration > 0) state.seek(position.inMicroseconds / duration);
    _publishPlayback();
  }

  @override
  Future<void> stop() async {
    if (!_acceptCommands) return;
    _stopped = true;
    state.stop();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (!_acceptCommands) return;
    if ((shuffleMode != AudioServiceShuffleMode.none) != state.shuffle) {
      state.toggleShuffle();
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    if (!_acceptCommands) return;
    final target = switch (repeatMode) {
      AudioServiceRepeatMode.none => LoopMode.off,
      AudioServiceRepeatMode.one => LoopMode.one,
      _ => LoopMode.all,
    };
    while (state.repeat != target) {
      state.cycleRepeat();
    }
  }

  @override
  Future<void> onTaskRemoved() => stop();
  void close() {
    _closed = true;
    ++_artGeneration;
    _clock?.cancel();
    state.removeListener(_stateChanged);
  }
}
