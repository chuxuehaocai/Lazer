import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Gateway extends MusicGateway {
  final Map<String, MusicSong> songs = <String, MusicSong>{};
  int songCalls = 0;

  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
  @override
  String get connectionId => 'main';
  @override
  MusicUser? get user => null;
  @override
  Set<MusicCapability> get capabilities => const <MusicCapability>{};

  @override
  Future<MusicSong> song(MusicId id) async {
    songCalls++;
    return songs[id.value]!;
  }
}

class _Catalog extends Catalog {
  _Catalog(MusicGateway gateway) : super(gateway: gateway);

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

class _Library extends LocalLibrary {
  @override
  Future<void> load() async {}
}

class _Plugins extends PluginManager {
  _Plugins({required this.listening});
  final bool listening;
  final List<String> events = <String>[];

  @override
  bool get hasPlayerEventListeners => listening;

  @override
  void broadcastPlayerEvent(String type, Map<String, dynamic> data) =>
      events.add(type);
}

Future<void> _settle(bool Function() done) async {
  for (var turn = 0; turn < 200 && !done(); turn++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue);
  for (var turn = 0; turn < 10; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  late _Gateway gateway;
  late _Library library;
  late List<int> encodedLengths;

  AppState state({PluginManager? plugins}) => AppState(
    catalog: _Catalog(gateway),
    localLibrary: library,
    pluginManager: plugins,
    skipUnavailableSongs: false,
    artworkSeedLoader: (_) async => null,
    listeningStatistics: ListeningStatisticsController(
      read: () async => null,
      write: (_) async {},
    ),
    queueStore: PlaybackQueueStore(
      encode: (List<Track> tracks) async {
        encodedLengths.add(tracks.length);
        return '[]';
      },
      write: (_) async {},
      read: () async => null,
    ),
  );

  MusicSong song(String value, {String? coverUrl}) => MusicSong(
    id: gateway.id(MusicEntityKind.song, value),
    title: 'Song $value',
    artists: <MusicArtist>[
      MusicArtist(
        id: gateway.id(MusicEntityKind.artist, 'artist'),
        name: 'Artist',
      ),
    ],
    albumName: 'Album',
    albumId: gateway.id(MusicEntityKind.album, 'album'),
    duration: const Duration(minutes: 3),
    coverUrl: coverUrl,
  );

  setUp(() {
    gateway = _Gateway();
    library = _Library();
    encodedLengths = <int>[];
  });

  test('a detail reply that adds nothing is not a queue edit', () async {
    final AppState app = state();
    addTearDown(() {
      app.dispose();
      library.dispose();
    });
    const String cover = 'https://images.test/cover.jpg';
    gateway.songs['1'] = song('1', coverUrl: cover);
    final List<Track> tracks = <Track>[
      for (final String value in <String>['1', '2', '3'])
        app.catalog.trackFromMusicSong(song(value, coverUrl: cover)),
    ];

    app.playQueue(tracks);
    final int revision = app.queueRevision;
    final List<Track> snapshot = app.queue;
    await _settle(() => gateway.songCalls == 1);

    expect(app.queueRevision, revision);
    expect(identical(app.queue, snapshot), isTrue);
    expect(identical(app.queue.first, tracks.first), isTrue);
    expect(encodedLengths, <int>[3]);
  });

  test('a detail reply with new artwork still updates the queue', () async {
    final AppState app = state();
    addTearDown(() {
      app.dispose();
      library.dispose();
    });
    const String cover = 'https://images.test/cover.jpg';
    gateway.songs['1'] = song('1', coverUrl: cover);
    final List<Track> tracks = <Track>[
      for (final String value in <String>['1', '2', '3'])
        app.catalog.trackFromMusicSong(song(value)),
    ];

    app.playQueue(tracks);
    final int revision = app.queueRevision;
    await _settle(() => gateway.songCalls == 1);

    expect(app.queueRevision, revision + 1);
    expect(app.queue.first.coverUrl, cover);
    expect(app.queue.first.title, tracks.first.title);
    expect(identical(app.queue[1], tracks[1]), isTrue);
    expect(identical(app.queue[2], tracks[2]), isTrue);
    expect(encodedLengths, <int>[3, 3]);
  });

  test('player events are not serialised when no plugin can receive them', () {
    final _Plugins idle = _Plugins(listening: false);
    final AppState quiet = state(plugins: idle);
    quiet.playQueue(<Track>[quiet.catalog.trackFromMusicSong(song('1'))]);
    expect(idle.events, isEmpty);
    quiet.dispose();

    final _Plugins active = _Plugins(listening: true);
    final AppState loud = state(plugins: active);
    loud.playQueue(<Track>[loud.catalog.trackFromMusicSong(song('1'))]);
    expect(active.events, containsAll(<String>['track', 'queue', 'status']));
    loud.dispose();
    library.dispose();
  });
}
