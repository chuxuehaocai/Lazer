import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _CachePath extends PathProviderPlatform {
  @override
  Future<String> getTemporaryPath() async =>
      Directory('build/test/still-alive-cache').absolute.path;
}

class _Platform extends JustAudioPlatform {
  late _Player player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      player = _Player(request.id);

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    await player.events.close();
    return DisposePlayerResponse();
  }
}

/// Models the desktop plugin's EOF behavior: position becomes zero at EOF,
/// and seeking alone leaves processingState completed until a fresh load.
class _Player extends AudioPlayerPlatform {
  _Player(super.id);
  final events = StreamController<PlaybackEventMessage>.broadcast(sync: true);
  var status = ProcessingStateMessage.idle;
  var position = Duration.zero;
  var active = false;
  final commands = <String>[];
  Completer<void>? loading;
  static const duration = Duration(seconds: 176);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  void report() => events.add(
    PlaybackEventMessage(
      processingState: status,
      updateTime: DateTime.now(),
      updatePosition: position,
      bufferedPosition: duration,
      duration: duration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ),
  );

  void finish() {
    active = false;
    position = Duration.zero;
    status = ProcessingStateMessage.completed;
    report();
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    commands.add('load');
    status = ProcessingStateMessage.loading;
    position = request.initialPosition ?? Duration.zero;
    report();
    await loading?.future;
    status = ProcessingStateMessage.ready;
    report();
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    commands.add('play');
    active = status != ProcessingStateMessage.completed;
    report();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    commands.add('pause');
    active = false;
    report();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    commands.add('seek');
    position = request.position ?? Duration.zero;
    report();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();
  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async => SetAndroidAudioAttributesResponse();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Platform platform;
  late StillAliveAudio audio;
  setUp(() {
    final originalPlatform = JustAudioPlatform.instance;
    final originalPath = PathProviderPlatform.instance;
    addTearDown(() {
      JustAudioPlatform.instance = originalPlatform;
      PathProviderPlatform.instance = originalPath;
      debugDefaultTargetPlatformOverride = null;
    });
    // Exercise the actual just_audio adapter without installing a desktop
    // registry over the deterministic platform used by this test.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    JustAudioPlatform.instance = platform = _Platform();
    PathProviderPlatform.instance = _CachePath();
    audio = StillAliveAudio();
    addTearDown(() async {
      await audio.close();
      audio.dispose();
    });
  });

  Future<void> drain() => Future<void>.delayed(Duration.zero);

  test(
    'real adapter reopens EOF and supports repeated completed replays',
    () async {
      await audio.play();
      await drain();
      final player = platform.player;
      expect(player.active, isTrue);
      for (var replay = 0; replay < 3; replay++) {
        player.finish();
        await drain();
        expect(audio.playing, isFalse);
        expect(audio.position, _Player.duration);
        // This is the sequence used by the terminal's replay introduction.
        await audio.pause();
        await audio.restart();
        await drain();
        expect(player.status, ProcessingStateMessage.ready);
        expect(player.active, isTrue);
        expect(audio.playing, isTrue);
        expect(audio.position, lessThan(const Duration(seconds: 1)));
      }
      expect(
        player.commands.where((command) => command == 'load'),
        hasLength(4),
      );
    },
  );

  test('real adapter uses seek for a replay before EOF', () async {
    await audio.play();
    await drain();
    final player = platform.player;
    player.position = const Duration(seconds: 30);
    player.report();
    await drain();
    await audio.restart();
    await drain();
    expect(player.commands.where((command) => command == 'load'), hasLength(1));
    expect(player.commands, contains('seek'));
    expect(player.active, isTrue);
    expect(audio.playing, isTrue);
  });

  test(
    'pause cancels an EOF replay waiting for its fresh decoder load',
    () async {
      await audio.play();
      await drain();
      final player = platform.player;
      player.finish();
      await drain();
      player.loading = Completer<void>();
      final restarting = audio.restart();
      final waiting = Stopwatch()..start();
      while (player.commands.where((command) => command == 'load').length < 2) {
        if (waiting.elapsed > const Duration(seconds: 5)) {
          fail('Completed replay never reopened its decoder: ${audio.error}');
        }
        await drain();
      }
      await audio.pause();
      player.loading!.complete();
      await restarting;
      await drain();
      expect(player.active, isFalse);
      expect(audio.playing, isFalse);
      expect(audio.error, isNull);
      await audio.play();
      await drain();
      expect(player.active, isTrue);
      expect(audio.playing, isTrue);
    },
  );
}
