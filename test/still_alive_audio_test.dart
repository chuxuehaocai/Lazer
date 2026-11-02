import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_audio.dart';

class _Backend implements StillAliveAudioBackend {
  final events = StreamController<StillAliveAudioSnapshot>.broadcast(
    sync: true,
  );
  final failures = StreamController<Object>.broadcast(sync: true);
  final commands = <String>[];
  Completer<Duration?>? loading;
  Completer<void>? starting;
  Completer<void>? seeking;
  Completer<void>? volumeSetting;
  Object? loadFailure;
  Object? playFailure;
  Object? pauseFailure;
  bool failStop = false, failDispose = false;
  int disposals = 0;
  Duration at = Duration.zero;
  Duration? length = const Duration(seconds: 180);
  bool active = false;
  double volume = 1;
  Object? volumeFailure;

  @override
  Stream<StillAliveAudioSnapshot> get snapshots => events.stream;
  @override
  Stream<Object> get errors => failures.stream;

  void emit({
    Duration? position,
    bool? playing,
    StillAliveAudioStatus status = StillAliveAudioStatus.ready,
  }) {
    at = position ?? at;
    active = playing ?? active;
    events.add(
      StillAliveAudioSnapshot(
        position: at,
        playing: active,
        status: status,
        duration: length,
      ),
    );
  }

  @override
  Future<Duration?> load(String asset) async {
    commands.add('load:$asset');
    if (loadFailure case final error?) throw error;
    final loaded = await (loading?.future ?? Future.value(length));
    emit(playing: false);
    return loaded;
  }

  @override
  Future<void> play() async {
    commands.add('play');
    await starting?.future;
    if (playFailure case final error?) throw error;
    emit(playing: true);
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    if (pauseFailure case final error?) throw error;
    emit(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    commands.add('seek:${position.inMilliseconds}');
    await seeking?.future;
    emit(position: position);
  }

  @override
  Future<void> setVolume(double value) async {
    await volumeSetting?.future;
    if (volumeFailure case final error?) throw error;
    volume = value;
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    if (failStop) throw StateError('stop failed');
    active = false;
  }

  @override
  Future<void> dispose() async {
    commands.add('dispose');
    disposals++;
    if (failDispose) throw StateError('dispose failed');
  }

  Future<void> finish() async {
    await events.close();
    await failures.close();
  }
}

void main() {
  test(
    'completed at zero after seek cannot cancel a replay before ready playback',
    () async {
      var now = Duration.zero;
      final backend = _Backend();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(
        backendFactory: () => backend,
        clock: () => now,
      );
      addTearDown(audio.dispose);
      await audio.play();
      backend.emit(
        position: backend.length,
        status: StillAliveAudioStatus.completed,
      );
      backend.starting = Completer<void>();
      final replay = audio.restart();
      await Future<void>.delayed(Duration.zero);
      expect(backend.commands.last, 'play');
      backend.emit(
        position: Duration.zero,
        playing: false,
        status: StillAliveAudioStatus.completed,
      );
      backend.emit(
        position: const Duration(milliseconds: 5),
        playing: true,
        status: StillAliveAudioStatus.buffering,
      );
      backend.emit(
        position: Duration.zero,
        playing: true,
        status: StillAliveAudioStatus.completed,
      );
      expect(audio.position, lessThan(const Duration(milliseconds: 20)));
      expect(audio.playing, isTrue);
      backend.starting!.complete();
      await replay;
      now += const Duration(milliseconds: 400);
      expect(audio.position, const Duration(milliseconds: 400));
      expect(backend.active, isTrue);
      expect(audio.error, isNull);
      await audio.close();
    },
  );

  test('the latest of overlapping restarts owns the next playback', () async {
    final backend = _Backend();
    addTearDown(backend.finish);
    final audio = StillAliveAudio(backendFactory: () => backend);
    addTearDown(audio.dispose);
    await audio.play();
    backend.emit(position: const Duration(seconds: 60));
    backend.seeking = Completer<void>();
    final first = audio.restart();
    await Future<void>.delayed(Duration.zero);
    final second = audio.restart();
    await Future<void>.delayed(Duration.zero);
    final playCount = backend.commands.where((value) => value == 'play').length;
    backend.seeking!.complete();
    await Future.wait([first, second]);
    expect(
      backend.commands.where((value) => value == 'play'),
      hasLength(playCount + 1),
    );
    expect(audio.playing, isTrue);
    expect(audio.position, lessThan(const Duration(milliseconds: 20)));
    await audio.close();
  });

  test(
    'pausing while replay starts still silences a late decoder start',
    () async {
      final backend = _Backend();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(backendFactory: () => backend);
      addTearDown(audio.dispose);
      await audio.play();
      backend.emit(
        position: backend.length,
        status: StillAliveAudioStatus.completed,
      );
      backend.starting = Completer<void>();
      final replay = audio.restart();
      await Future<void>.delayed(Duration.zero);
      await audio.pause();
      backend.starting!.complete();
      await replay;
      expect(audio.playing, isFalse);
      expect(backend.active, isFalse);
      expect(backend.commands.last, 'pause');
      expect(audio.error, isNull);
      await audio.close();
    },
  );

  for (final wasPlaying in [true, false]) {
    test(
      'completion to restart ignores late EOF while seeking ($wasPlaying)',
      () async {
        var now = Duration.zero;
        final backend = _Backend();
        addTearDown(backend.finish);
        final audio = StillAliveAudio(
          backendFactory: () => backend,
          clock: () => now,
        );
        addTearDown(audio.dispose);
        await audio.play();
        backend.emit(
          position: backend.length,
          playing: wasPlaying,
          status: StillAliveAudioStatus.completed,
        );
        expect(audio.position, backend.length);
        expect(audio.playing, isFalse);
        backend.seeking = Completer<void>();
        final restart = audio.restart();
        // A terminal report can also arrive before the ready load future's
        // first continuation, not only while the native seek is pending.
        backend.emit(
          position: backend.length,
          playing: wasPlaying,
          status: StillAliveAudioStatus.completed,
        );
        expect(audio.position, Duration.zero);
        await Future<void>.delayed(Duration.zero);
        backend.emit(
          position: Duration.zero,
          playing: wasPlaying,
          status: StillAliveAudioStatus.completed,
        );
        expect(audio.position, Duration.zero);
        expect(audio.playing, isFalse);
        backend.seeking!.complete();
        await restart;
        expect(backend.commands.last, 'play');
        expect(audio.position, Duration.zero);
        expect(audio.playing, isTrue);
        now += const Duration(milliseconds: 45);
        expect(audio.position, const Duration(milliseconds: 45));
        backend.emit(
          position: backend.length,
          playing: true,
          status: StillAliveAudioStatus.completed,
        );
        expect(
          audio.playing,
          isFalse,
          reason: 'a real completion after fresh playback still counts',
        );
        expect(audio.position, backend.length);
        await audio.close();
      },
    );
  }

  test(
    'a slow initial volume command cannot overwrite a newer main volume',
    () async {
      final backend = _Backend()..volumeSetting = Completer<void>();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(volume: .8, backendFactory: () => backend);
      addTearDown(audio.dispose);
      final play = audio.play();
      await Future<void>.delayed(Duration.zero);
      final changed = audio.setVolume(.05);
      backend.volumeSetting!.complete();
      await Future.wait([play, changed]);
      expect(backend.volume, .05);
      expect(audio.playing, isTrue);
      await audio.close();
    },
  );

  test(
    'volume stays lazy and applies the latest loading value before play',
    () async {
      final backend = _Backend()..loading = Completer<Duration?>();
      addTearDown(backend.finish);
      var created = 0;
      final audio = StillAliveAudio(
        volume: .8,
        backendFactory: () {
          created++;
          return backend;
        },
      );
      addTearDown(audio.dispose);
      await audio.setVolume(.35);
      expect(created, 0);
      final play = audio.play();
      await audio.setVolume(.12);
      backend.loading!.complete(backend.length);
      await play;
      expect(backend.volume, .12);
      expect(audio.playing, isTrue);
      await audio.close();
    },
  );

  test(
    'live main volume supports mute/unmute and survives reload retry',
    () async {
      final backend = _Backend();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(volume: .45, backendFactory: () => backend);
      addTearDown(audio.dispose);
      await audio.play();
      expect(backend.volume, .45);
      await audio.setVolume(0);
      expect(backend.volume, 0);
      expect(audio.playing, isTrue);
      await audio.setVolume(.7);
      expect(backend.volume, .7);
      backend.failures.add(StateError('decoder retry'));
      await audio.load();
      expect(backend.volume, .7);
      expect(audio.error, isNull);
      await audio.setVolume(2);
      expect(backend.volume, 1);
      await audio.setVolume(-2);
      expect(backend.volume, 0);
      backend.volumeFailure = StateError('volume output lost');
      await audio.setVolume(.2);
      expect(audio.error, contains('volume output lost'));
      backend.volumeFailure = null;
      await audio.load();
      expect(backend.volume, .2);
      expect(audio.error, isNull);
      await audio.close();
    },
  );

  test('desktop registration preserves an existing main-player registry', () {
    final previousPlatform = JustAudioPlatform.instance;
    addTearDown(() {
      JustAudioPlatform.instance = previousPlatform;
      debugDefaultTargetPlatformOverride = null;
    });
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      final registry = JustAudioMediaKit();
      JustAudioPlatform.instance = registry;
      ensureStillAliveDesktopAudioBackend();
      ensureStillAliveDesktopAudioBackend();
      expect(JustAudioPlatform.instance, same(registry));
    }
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      JustAudioPlatform.instance = previousPlatform;
      ensureStillAliveDesktopAudioBackend();
      expect(JustAudioPlatform.instance, same(previousPlatform));
    }
  });

  test(
    'construction is lazy and loading does not start a soundtrack',
    () async {
      var created = 0;
      final backend = _Backend();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(
        backendFactory: () {
          created++;
          return backend;
        },
      );
      addTearDown(audio.dispose);
      expect(created, 0);
      expect(audio.ready, isFalse);
      await Future.wait([audio.load(), audio.load()]);
      expect(created, 1);
      expect(backend.commands, ['load:$stillAliveAudioAsset']);
      expect(audio.ready, isTrue);
      expect(audio.playing, isFalse);
      expect(audio.position, Duration.zero);
      expect(audio.duration, backend.length);
      await audio.close();
      expect(backend.disposals, 1);
    },
  );

  test(
    'clock follows decoder anchors and freezes when paused or buffering',
    () async {
      var now = Duration.zero;
      final backend = _Backend();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(
        backendFactory: () => backend,
        clock: () => now,
      );
      addTearDown(audio.dispose);
      await audio.play();
      expect(audio.playing, isTrue);
      now = const Duration(milliseconds: 40);
      expect(audio.position, now);
      backend.emit(position: const Duration(seconds: 3));
      now += const Duration(milliseconds: 17);
      expect(audio.position, const Duration(milliseconds: 3017));
      backend.emit(
        position: const Duration(seconds: 3),
        status: StillAliveAudioStatus.buffering,
      );
      now += const Duration(seconds: 5);
      expect(audio.position, const Duration(seconds: 3));
      backend.emit(position: const Duration(seconds: 4));
      now += const Duration(milliseconds: 25);
      expect(audio.position, const Duration(milliseconds: 4025));
      await audio.pause();
      final paused = audio.position;
      now += const Duration(seconds: 20);
      expect(audio.position, paused);
      expect(audio.playing, isFalse);
      await audio.close();
    },
  );

  test('a background pause cancels a play waiting for asset loading', () async {
    final backend = _Backend()..loading = Completer<Duration?>();
    addTearDown(backend.finish);
    final audio = StillAliveAudio(backendFactory: () => backend);
    addTearDown(audio.dispose);
    final play = audio.play();
    await audio.pause();
    backend.loading!.complete(backend.length);
    await play;
    expect(backend.commands, isNot(contains('play')));
    expect(audio.playing, isFalse);
    await audio.close();
  });

  test('late paused decoder reports cannot move the frozen clock', () async {
    var now = Duration.zero;
    final backend = _Backend();
    addTearDown(backend.finish);
    final audio = StillAliveAudio(
      backendFactory: () => backend,
      clock: () => now,
    );
    addTearDown(audio.dispose);
    await audio.play();
    backend.emit(position: const Duration(seconds: 3));
    now += const Duration(milliseconds: 20);
    await audio.pause();
    final pausedAt = audio.position;
    backend.emit(
      position: pausedAt + const Duration(milliseconds: 51),
      playing: false,
    );
    now += const Duration(seconds: 5);
    expect(audio.position, pausedAt);
    expect(audio.playing, isFalse);
    // Even a late completion cannot jump a paused terminal to its end.
    backend.emit(
      position: backend.length,
      playing: false,
      status: StillAliveAudioStatus.completed,
    );
    expect(audio.position, pausedAt);
    await audio.restart();
    expect(audio.position, Duration.zero);
    expect(audio.playing, isTrue);
    now += const Duration(milliseconds: 25);
    expect(audio.position, const Duration(milliseconds: 25));
    await audio.pause();
    await audio.play();
    backend.emit(position: const Duration(seconds: 2));
    expect(audio.position, const Duration(seconds: 2));
    await audio.close();
  });

  test('a late decoder start cannot undo the user background pause', () async {
    final backend = _Backend()..starting = Completer<void>();
    addTearDown(backend.finish);
    final audio = StillAliveAudio(backendFactory: () => backend);
    addTearDown(audio.dispose);
    await audio.load();
    final play = audio.play();
    await Future<void>.delayed(Duration.zero);
    await audio.pause();
    backend.starting!.complete();
    await play;
    expect(audio.playing, isFalse);
    expect(backend.active, isFalse);
    expect(backend.commands.last, 'pause');
    expect(audio.error, isNull);
    await audio.close();
  });

  test(
    'restart seeks before playing and a pause cancels pending replay',
    () async {
      final backend = _Backend();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(backendFactory: () => backend);
      addTearDown(audio.dispose);
      await audio.play();
      backend.emit(position: const Duration(seconds: 30));
      await audio.restart();
      expect(backend.commands.sublist(backend.commands.length - 2), [
        'seek:0',
        'play',
      ]);
      expect(audio.position, lessThan(const Duration(milliseconds: 20)));
      backend.seeking = Completer<void>();
      final replay = audio.restart();
      await Future<void>.delayed(Duration.zero);
      await audio.pause();
      final playCount = backend.commands
          .where((command) => command == 'play')
          .length;
      backend.seeking!.complete();
      await replay;
      expect(
        backend.commands.where((command) => command == 'play'),
        hasLength(playCount),
      );
      expect(audio.playing, isFalse);
      await audio.close();
    },
  );

  test('completion clamps the clock and play replays from zero', () async {
    var now = Duration.zero;
    final backend = _Backend();
    addTearDown(backend.finish);
    final audio = StillAliveAudio(
      backendFactory: () => backend,
      clock: () => now,
    );
    addTearDown(audio.dispose);
    await audio.play();
    backend.emit(position: const Duration(seconds: 179));
    now += const Duration(seconds: 5);
    expect(audio.position, backend.length);
    backend.emit(
      position: backend.length,
      status: StillAliveAudioStatus.completed,
    );
    expect(audio.playing, isFalse);
    now += const Duration(minutes: 2);
    expect(audio.position, backend.length);
    await audio.play();
    expect(backend.commands.sublist(backend.commands.length - 2), [
      'seek:0',
      'play',
    ]);
    expect(audio.position, Duration.zero);
    await audio.close();
  });

  test('decode and output failures are visible and can be retried', () async {
    final backend = _Backend()..loadFailure = StateError('missing decoder');
    addTearDown(backend.finish);
    final audio = StillAliveAudio(backendFactory: () => backend);
    addTearDown(audio.dispose);
    await audio.play();
    expect(audio.ready, isFalse);
    expect(audio.playing, isFalse);
    expect(audio.error, contains('missing decoder'));
    backend.loadFailure = null;
    await audio.play();
    expect(audio.ready, isTrue);
    expect(audio.playing, isTrue);
    backend.failures.add(StateError('output disconnected'));
    expect(audio.playing, isFalse);
    expect(audio.error, contains('output disconnected'));
    await audio.close();
  });

  test('a failed pause can be reloaded and explicitly played again', () async {
    final backend = _Backend();
    addTearDown(backend.finish);
    final audio = StillAliveAudio(backendFactory: () => backend);
    addTearDown(audio.dispose);
    await audio.play();
    backend.pauseFailure = StateError('pause output lost');
    await audio.pause();
    expect(audio.ready, isFalse);
    expect(audio.playing, isFalse);
    expect(audio.error, contains('pause output lost'));
    backend.pauseFailure = null;
    await audio.load();
    expect(audio.ready, isTrue);
    expect(audio.error, isNull);
    await audio.play();
    expect(audio.playing, isTrue);
    await audio.close();
  });

  test(
    'audio focus denial is an error, never a simulated playing clock',
    () async {
      var now = Duration.zero;
      final backend = _Backend()
        ..playFailure = StateError('audio focus denied');
      addTearDown(backend.finish);
      final audio = StillAliveAudio(
        backendFactory: () => backend,
        clock: () => now,
      );
      addTearDown(audio.dispose);
      await audio.play();
      expect(audio.error, contains('audio focus denied'));
      expect(audio.playing, isFalse);
      now += const Duration(seconds: 20);
      expect(audio.position, Duration.zero);
      backend.playFailure = null;
      await audio.play();
      expect(audio.error, isNull);
      expect(audio.playing, isTrue);
      await audio.close();
    },
  );

  test(
    'closing while loading cannot start playback and releases exactly once',
    () async {
      final backend = _Backend()..loading = Completer<Duration?>();
      addTearDown(backend.finish);
      final audio = StillAliveAudio(backendFactory: () => backend);
      var notifications = 0;
      audio.addListener(() => notifications++);
      final play = audio.play();
      await audio.close();
      final closingNotifications = notifications;
      expect(
        backend.commands,
        containsAllInOrder(['pause', 'stop', 'dispose']),
      );
      expect(backend.events.hasListener, isFalse);
      expect(backend.failures.hasListener, isFalse);
      backend.loading!.complete(backend.length);
      await play;
      expect(backend.commands, isNot(contains('play')));
      expect(audio.ready, isFalse);
      expect(audio.playing, isFalse);
      expect(notifications, closingNotifications);
      audio.dispose();
      audio.dispose();
      await audio.close();
      expect(backend.disposals, 1);
    },
  );

  test(
    'dispose silences synchronously and still releases a broken backend',
    () async {
      final backend = _Backend()
        ..failStop = true
        ..failDispose = true;
      addTearDown(backend.finish);
      final audio = StillAliveAudio(backendFactory: () => backend);
      await audio.play();
      expect(backend.active, isTrue);
      audio.dispose();
      expect(audio.playing, isFalse);
      expect(backend.active, isFalse);
      await audio.close();
      expect(backend.disposals, 1);
      expect(backend.events.hasListener, isFalse);
    },
  );
}
