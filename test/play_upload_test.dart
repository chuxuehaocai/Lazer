import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const GatewayUserProfile _profile = GatewayUserProfile(
  userId: 7,
  nickname: '测试账户',
);

const Track _track = Track(
  id: '42',
  title: 'Short song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(seconds: 8),
  coverSeed: 1,
);

class _Gateway extends NeteaseGateway {
  final List<(int, int, int)> uploads = <(int, int, int)>[];
  final List<(int, int)> starts = <(int, int)>[];
  bool failUploads = false;

  @override
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    sessionCookie = 'MUSIC_U=fixture';
    return const GatewayLoginStatus(profile: _profile);
  }

  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};

  @override
  Future<List<GatewayPlayRecord>> playRecord(int uid) async =>
      const <GatewayPlayRecord>[];

  @override
  Future<void> reportPlayStart({
    required int songId,
    required int sourceId,
  }) async {
    if (failUploads) throw StateError('offline');
    starts.add((songId, sourceId));
  }

  @override
  Future<void> reportPlayback({
    required int songId,
    required int playedSeconds,
    int sourceId = 0,
  }) async {
    if (failUploads) throw StateError('offline');
    uploads.add((songId, playedSeconds, sourceId));
  }
}

class _Catalog extends Catalog {
  _Catalog(_Gateway gateway) : super(gateway: gateway);

  int playStatsCalls = 0;

  @override
  Future<UserCollections?> cachedUserCollections(int uid) async => null;

  @override
  Future<UserCollections> userCollections(int uid) async =>
      UserCollections.empty;

  @override
  Future<void> invalidateCollections(int uid) async {}

  @override
  Future<void> invalidatePlayStats(int uid) async {}

  @override
  Future<List<TrackPlayStat>> playStats(int uid, {bool force = false}) async {
    playStatsCalls++;
    return const <TrackPlayStat>[
      TrackPlayStat(songId: '42', playCount: 1, duration: Duration(seconds: 8)),
    ];
  }

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'file:///fixture.mp3';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

class _Engine implements AudioEngine {
  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => _track.duration;

  @override
  Stream<void> get completed => const Stream<void>.empty();

  @override
  Future<void> setUrl(String url) async => active = true;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async => this.position = position;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async => active = false;

  @override
  void dispose() {}
}

class _Harness {
  _Harness(this.state, this.engine, this.gateway);

  final AppState state;
  final _Engine engine;
  final _Gateway gateway;
}

Future<_Harness> _signedIn() async {
  final _Gateway gateway = _Gateway();
  final _Engine engine = _Engine();
  final AppState state = AppState(
    catalog: _Catalog(gateway),
    audioEngine: engine,
  );
  addTearDown(state.dispose);
  final AuthOutcome outcome = await state.signInWithCookie('MUSIC_U=fixture');
  expect(outcome.ok, isTrue);
  return _Harness(state, engine, gateway);
}

/// Runs four one-second position steps, which is half of the fixture track
/// and therefore exactly the qualifying threshold.
Future<void> _playQualified(WidgetTester tester, _Harness harness) async {
  harness.state.playQueue(const <Track>[_track]);
  await tester.pump();
  expect(harness.engine.active, isTrue, reason: 'the fixture URL loaded');

  // The first active tick establishes the session's starting position.
  await tester.pump(const Duration(milliseconds: 100));
  for (var second = 1; second <= 4; second++) {
    harness.engine.position = Duration(seconds: second);
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a qualified play uploads once and clears the persisted queue', (
    tester,
  ) async {
    final _Harness harness = await _signedIn();
    await _playQualified(tester, harness);

    harness.state.pause();
    await tester.pump();
    await tester.pump();

    // The client-log pair: a start log credits 最近播放, the play log credits
    // 听歌排行 with the album/song id the official client sends as sourceId.
    expect(harness.gateway.starts, <(int, int)>[(42, 42)]);
    expect(harness.gateway.uploads, <(int, int, int)>[(42, 4, 42)]);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lazer_play_uploads'), '[]');
  });

  testWidgets('an offline play stays queued on disk and uploads on retry', (
    tester,
  ) async {
    final _Harness harness = await _signedIn();
    harness.gateway.failUploads = true;
    await _playQualified(tester, harness);

    harness.state.pause();
    await tester.pump();
    await tester.pump();

    expect(harness.gateway.uploads, isEmpty);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('lazer_play_uploads'),
      '[{"songId":42,"kind":"start","seconds":0,"sourceId":42},'
      '{"songId":42,"kind":"play","seconds":4,"sourceId":42}]',
    );

    // The next library visit pushes the backlog before reading the record.
    harness.gateway.failUploads = false;
    await harness.state.loadPlayStats(force: true);
    await tester.pump();

    expect(harness.gateway.starts, <(int, int)>[(42, 42)]);
    expect(harness.gateway.uploads, <(int, int, int)>[(42, 4, 42)]);
    expect(prefs.getString('lazer_play_uploads'), '[]');
  });

  testWidgets('an upload retires the loaded play record for the next visit', (
    tester,
  ) async {
    final _Harness harness = await _signedIn();
    await harness.state.loadPlayStats();
    final _Catalog catalog = harness.state.catalog as _Catalog;
    expect(catalog.playStatsCalls, 1);
    expect(harness.state.playStats, hasLength(1));

    await _playQualified(tester, harness);
    harness.state.pause();
    await tester.pump();
    await tester.pump();
    expect(harness.gateway.uploads, isNotEmpty);

    // The list loaded before the play must not answer the next visit from
    // AppState's own copy; it has to ask the (invalidated) catalogue again.
    await harness.state.loadPlayStats();
    expect(catalog.playStatsCalls, 2);
  });
}
