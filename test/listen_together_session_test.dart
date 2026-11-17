import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/listen_together.dart';
import 'package:lazer_nextgen/widgets/listen_together_dialog.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

import 'support/music_gateway.dart';

class _Gateway extends TestMusicGateway {
  final calls = <(String, Map<String, dynamic>)>[];
  final responses = <String, Future<Map<String, dynamic>> Function()>{};
  Completer<MusicSong>? pendingSong;
  String account = '7';
  bool supported = true;
  int songRequests = 0;

  @override
  MusicUser get user => MusicUser(
    id: id(MusicEntityKind.user, account),
    name: 'Listener $account',
  );
  @override
  Set<MusicCapability> get capabilities => {
    if (supported) MusicCapability.listenTogether,
  };
  @override
  Future<Map<String, dynamic>> listenTogether(
    String operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add((operation, args));
    if (responses[operation] case final response?) return response();
    return operation == 'create' || operation == 'createMulti'
        ? {'roomId': 'room', 'inviterId': account}
        : {'code': 200};
  }

  @override
  Future<MusicSong> song(MusicId id) {
    songRequests++;
    return pendingSong!.future;
  }
}

class _State extends AppState {
  _State(_Gateway gateway) : super(catalog: Catalog(gateway: gateway));
  List<Track> tracks = [];
  int starts = 0;
  bool playback = false;
  Duration fixturePosition = Duration.zero;
  final fixtureTicks = ChangeNotifier();
  final seeks = <Duration>[];
  @override
  Duration get position => fixturePosition;
  @override
  Listenable get ticks => fixtureTicks;
  @override
  bool get playing => playback;
  void toggleFixturePlayback() {
    playback = !playback;
    notifyListeners();
  }

  void seekFixture(int millis) {
    fixturePosition = Duration(milliseconds: millis);
    fixtureTicks.notifyListeners();
  }

  @override
  void play() {
    playback = true;
    notifyListeners();
  }

  @override
  void togglePlay() => toggleFixturePlayback();

  @override
  Future<void> seekTo(Duration target) async {
    seeks.add(target);
    fixturePosition = target;
  }

  @override
  List<Track> get queue => tracks;
  @override
  Track? get current => tracks.firstOrNull;
  @override
  void playQueue(List<Track> tracks, {int startIndex = 0}) {
    this.tracks = tracks;
    playback = true;
    starts++;
  }

  @override
  void dispose() {
    super.dispose();
    fixtureTicks.dispose();
  }
}

Track _track(_Gateway gateway, String id) => Track(
  id: gateway.id(MusicEntityKind.song, id).cacheKey,
  title: id,
  artist: '',
  album: '',
  duration: const Duration(minutes: 3),
  coverSeed: 0,
);

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Gateway gateway;
  late _State state;
  late ListenTogetherController room;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    gateway = _Gateway();
    state = _State(gateway);
    room = state.listenTogether;
  });
  tearDown(() => state.dispose());

  test(
    'slow command service retains only the newest pending playback state',
    () async {
      state.tracks = [
        Track(
          id: gateway.id(MusicEntityKind.song, 'one').cacheKey,
          title: 'One',
          artist: '',
          album: '',
          duration: const Duration(minutes: 3),
          coverSeed: 0,
        ),
      ];
      final response = Completer<Map<String, dynamic>>();
      gateway.responses['command'] = () => response.future;
      await room.create();
      for (var i = 0; i < 1000; i++) {
        state.toggleFixturePlayback();
      }
      expect(gateway.calls.where((call) => call.$1 == 'command'), hasLength(1));
      response.complete({'code': 200});
      await _settle();
      final commands = gateway.calls
          .where((call) => call.$1 == 'command')
          .toList();
      expect(commands, hasLength(2));
      expect((commands.last.$2['command'] as Map)['playStatus'], 'PAUSE');
    },
  );

  for (final initialPlaying in [false, true]) {
    test(
      'coalesced seek preserves ${initialPlaying ? 'PAUSE' : 'PLAY'} intent',
      () async {
        state.tracks = [_track(gateway, 'one')];
        state.playback = initialPlaying;
        final response = Completer<Map<String, dynamic>>();
        gateway.responses['command'] = () => response.future;
        await room.create();
        state.toggleFixturePlayback();
        state.seekFixture(12000);
        response.complete({'code': 200});
        await _settle();
        final sent = gateway.calls
            .where((call) => call.$1 == 'command')
            .toList();
        expect(sent, hasLength(2));
        final command = sent.last.$2['command'] as Map;
        expect(command['commandType'], initialPlaying ? 'PAUSE' : 'PLAY');
        expect(command['playStatus'], initialPlaying ? 'PAUSE' : 'PLAY');
        expect(command['targetSongId'], 'one');
        expect(command['progress'], 12000);
      },
    );
  }

  test('ordinary seek keeps the legacy PROGRESS command type', () async {
    state.tracks = [_track(gateway, 'one')];
    await room.create();
    await _settle();
    state.seekFixture(12000);
    await _settle();
    final sent = gateway.calls.lastWhere((call) => call.$1 == 'command');
    expect((sent.$2['command'] as Map)['commandType'], 'PROGRESS');
  });

  test('PROGRESS with PLAY resumes the named current track', () async {
    state.tracks = [_track(gateway, 'one')];
    await room.create();
    gateway.responses['status'] = () async => {
      'command': {
        'commandType': 'PROGRESS',
        'playStatus': 'PLAY',
        'targetSongId': 'one',
        'progress': 12000,
        'serverSeq': 1,
      },
    };
    await room.refresh();
    await _settle();
    expect(state.playing, isTrue);
    expect(state.position, const Duration(seconds: 12));
    expect(state.starts, 0);
  });

  test('PROGRESS with PLAY adopts its new target and position', () async {
    state.tracks = [_track(gateway, 'one')];
    await room.create();
    gateway.pendingSong = Completer<MusicSong>();
    gateway.responses['status'] = () async => {
      'command': {
        'commandType': 'PROGRESS',
        'playStatus': 'PLAY',
        'targetSongId': 'remote',
        'progress': 12000,
        'serverSeq': 1,
      },
    };
    await room.refresh();
    expect(gateway.songRequests, 1);
    gateway.pendingSong!.complete(
      MusicSong(
        id: gateway.id(MusicEntityKind.song, 'remote'),
        title: 'Remote',
        artists: [],
        duration: const Duration(minutes: 3),
      ),
    );
    await _settle();
    expect(
      state.current?.id,
      gateway.id(MusicEntityKind.song, 'remote').cacheKey,
    );
    expect(state.playing, isTrue);
    expect(state.position, const Duration(seconds: 12));
  });

  for (final type in ['PLAY', 'PROGRESS']) {
    test('$type with PAUSE never starts a different target', () async {
      state.tracks = [_track(gateway, 'one')];
      state.playback = true;
      await room.create();
      gateway.responses['status'] = () async => {
        'command': {
          'commandType': type,
          'playStatus': 'PAUSE',
          'targetSongId': 'remote',
          'progress': 12000,
          'serverSeq': 1,
        },
      };
      await room.refresh();
      await _settle();
      expect(state.playing, isFalse);
      expect(state.starts, 0);
      expect(gateway.songRequests, 0);
      expect(state.seeks, isEmpty);
    });
  }

  test(
    'paused current track accepts coalesced progress without starting',
    () async {
      state.tracks = [_track(gateway, 'one')];
      await room.create();
      gateway.responses['status'] = () async => {
        'command': {
          'commandType': 'PAUSE',
          'playStatus': 'PAUSE',
          'targetSongId': 'one',
          'progress': 12000,
          'serverSeq': 1,
        },
      };
      await room.refresh();
      await _settle();
      expect(state.playing, isFalse);
      expect(state.position, const Duration(seconds: 12));
    },
  );

  test('legacy PROGRESS without playback status only seeks', () async {
    state.tracks = [_track(gateway, 'one')];
    await room.create();
    gateway.responses['status'] = () async => {
      'command': {'commandType': 'PROGRESS', 'progress': 12000, 'serverSeq': 1},
    };
    await room.refresh();
    await _settle();
    expect(state.playing, isFalse);
    expect(state.position, const Duration(seconds: 12));
  });

  for (final (type, status, target) in [
    ('PROGRESS', 'PAUSE', 'remote'),
    ('PROGRESS', 'PLAY', 'one'),
    ('PLAY', 'PLAY', 'one'),
  ]) {
    test('$type/$status/$target invalidates an older target lookup', () async {
      state.tracks = [_track(gateway, 'one')];
      await room.create();
      gateway.pendingSong = Completer<MusicSong>();
      gateway.responses['status'] = () async => {
        'command': {
          'commandType': 'PLAY',
          'playStatus': 'PLAY',
          'targetSongId': 'remote',
          'serverSeq': 1,
        },
      };
      await room.refresh();
      expect(gateway.songRequests, 1);
      gateway.responses['status'] = () async => {
        'command': {
          'commandType': type,
          'playStatus': status,
          'targetSongId': target,
          'progress': 12000,
          'serverSeq': 2,
        },
      };
      await room.refresh();
      gateway.pendingSong!.complete(
        MusicSong(
          id: gateway.id(MusicEntityKind.song, 'remote'),
          title: 'Remote',
          artists: [],
          duration: const Duration(minutes: 3),
        ),
      );
      await _settle();
      expect(state.starts, 0);
      expect(
        state.current?.id,
        gateway.id(MusicEntityKind.song, 'one').cacheKey,
      );
      expect(state.playing, status == 'PLAY');
    });
  }

  test('legacy seek for another target cannot move the current song', () async {
    state.tracks = [_track(gateway, 'one')];
    await room.create();
    gateway.responses['status'] = () async => {
      'command': {
        'commandType': 'PROGRESS',
        'targetSongId': 'other',
        'progress': 12000,
        'serverSeq': 1,
      },
    };
    await room.refresh();
    await _settle();
    expect(state.seeks, isEmpty);
    expect(state.playing, isFalse);
  });

  test('repeated remote status shares a pending song lookup', () async {
    await room.create();
    gateway.pendingSong = Completer<MusicSong>();
    gateway.responses['status'] = () async => {'songId': 'remote'};
    for (var i = 0; i < 20; i++) {
      await room.refresh();
    }
    expect(gateway.songRequests, 1);
    gateway.pendingSong!.complete(
      MusicSong(
        id: gateway.id(MusicEntityKind.song, 'remote'),
        title: 'Remote',
        artists: [],
        duration: const Duration(minutes: 3),
      ),
    );
    await _settle();
    expect(state.starts, 1);
  });

  test(
    'a pause arriving during remote lookup prevents a late playback start',
    () async {
      await room.create();
      gateway.pendingSong = Completer<MusicSong>();
      gateway.responses['status'] = () async => {
        'songId': 'remote',
        'playStatus': 'PLAY',
      };
      await room.refresh();
      expect(gateway.songRequests, 1);
      gateway.responses['status'] = () async => {
        'command': {'commandType': 'PAUSE', 'serverSeq': 1, 'userId': 'other'},
      };
      await room.refresh();
      gateway.pendingSong!.complete(
        MusicSong(
          id: gateway.id(MusicEntityKind.song, 'remote'),
          title: 'Remote',
          artists: [],
          duration: const Duration(minutes: 3),
        ),
      );
      await _settle();
      expect(state.starts, 0);
      expect(state.playing, isFalse);
    },
  );

  test(
    'a paused room with a different track cannot start local playback',
    () async {
      await room.create();
      gateway.responses['status'] = () async => {
        'songId': 'remote',
        'playStatus': 'PAUSE',
      };
      await room.refresh();
      await _settle();
      expect(gateway.songRequests, 0);
      expect(state.starts, 0);
      expect(state.playing, isFalse);
    },
  );

  testWidgets(
    'late leave closes its own room dialog without popping a covering route',
    (tester) async {
      await room.create();
      final response = Completer<Map<String, dynamic>>();
      gateway.responses['leave'] = () => response.future;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: buildAppleTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    unawaited(showListenTogetherDialog(context, state)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('结束一起听'));
      await tester.tap(find.text('结束一起听'));
      await tester.pump();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering page')),
        ),
      );
      await tester.pumpAndSettle();
      response.complete({'code': 200});
      await tester.pumpAndSettle();
      expect(find.text('Covering page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'creates an invite room without matchmaking and accepts invite forms',
    () async {
      expect(await room.create(), isTrue);
      expect(room.ready, isTrue);
      expect(gateway.calls.first.$1, 'create');
      expect(ListenTogetherController.parseInvite('123|456'), ('123', '456'));
      expect(
        ListenTogetherController.parseInvite(
          'https://example.com/?roomId=123&inviterId=456',
        ),
        ('123', '456'),
      );
      expect(ListenTogetherController.parseInvite('|456'), (null, null));
      expect(ListenTogetherController.parseInvite('123|456|789'), (null, null));
    },
  );

  test('repeated room submit does not create a second server room', () async {
    final response = Completer<Map<String, dynamic>>();
    gateway.responses['create'] = () => response.future;
    final first = room.create();
    final second = room.create();
    response.complete({'roomId': 'one'});
    await Future.wait([first, second]);
    expect(gateway.calls.where((call) => call.$1 == 'create'), hasLength(1));
  });

  test('leaving while create is pending cannot resurrect the room', () async {
    final response = Completer<Map<String, dynamic>>();
    gateway.responses['create'] = () => response.future;
    final opening = room.create();
    await room.leave();
    response.complete({'roomId': 'late'});
    expect(await opening, isFalse);
    expect(room.ready, isFalse);
    expect(room.roomId, isNull);
    expect(gateway.calls.where((call) => call.$1 == 'heartbeat'), isEmpty);
  });

  test('changing the account during join invalidates the reply', () async {
    final response = Completer<Map<String, dynamic>>();
    gateway.responses['join'] = () => response.future;
    final joining = room.join('room|inviter');
    gateway.account = '8';
    response.complete({'code': 200});
    expect(await joining, isFalse);
    expect(room.ready, isFalse);
  });

  test('join checks capability before contacting the provider', () async {
    gateway.supported = false;
    expect(await room.join('room|inviter'), isFalse);
    expect(gateway.calls, isEmpty);
  });

  test('late status does not replace a new room roster', () async {
    await room.create();
    final status = Completer<Map<String, dynamic>>();
    gateway.responses['status'] = () => status.future;
    final refreshing = room.refresh();
    await room.leave();
    await room.create();
    status.complete({
      'members': [
        {'userId': 'old', 'name': 'Previous room'},
      ],
    });
    await refreshing;
    expect(room.members, isEmpty);
  });

  test(
    'repeated status refresh coalesces while the request is pending',
    () async {
      await room.create();
      final status = Completer<Map<String, dynamic>>();
      gateway.responses['status'] = () => status.future;
      final refreshes = List.generate(20, (_) => room.refresh());
      status.complete({'code': 200});
      await Future.wait(refreshes);
      expect(gateway.calls.where((call) => call.$1 == 'status'), hasLength(1));
    },
  );

  test(
    'room envelopes and explicit empty rosters and queues are applied',
    () async {
      await room.create();
      gateway.responses['status'] = () async => {
        'data': {
          'members': [
            {'userId': '8', 'name': 'Friend'},
          ],
          'playlist': [
            {'id': 'a', 'name': 'A'},
          ],
        },
      };
      await room.refresh();
      expect(room.members.single.name, 'Friend');
      expect(room.roomQueue.single.title, 'A');
      gateway.responses['status'] = () async => {
        'data': {'members': [], 'playlist': []},
      };
      await room.refresh();
      expect(room.members, isEmpty);
      expect(room.roomQueue, isEmpty);
    },
  );

  test(
    'incoming room data has the same queue budget as outgoing data',
    () async {
      await room.create();
      gateway.responses['status'] = () async => {
        'playlist': List.generate(10000, (i) => {'id': '$i'}),
        'members': List.generate(10000, (i) => {'userId': '$i'}),
      };
      await room.refresh();
      expect(room.roomQueue.length, lessThanOrEqualTo(200));
      expect(room.members.length, lessThanOrEqualTo(200));
    },
  );

  test('remote song lookup cannot start playback after leaving', () async {
    await room.create();
    gateway.pendingSong = Completer<MusicSong>();
    gateway.responses['status'] = () async => {'songId': 'remote'};
    await room.refresh();
    await room.leave();
    gateway.pendingSong!.complete(
      MusicSong(
        id: gateway.id(MusicEntityKind.song, 'remote'),
        title: 'Remote',
        artists: [],
        duration: const Duration(minutes: 3),
      ),
    );
    await _settle();
    expect(state.starts, 0);
  });
}
