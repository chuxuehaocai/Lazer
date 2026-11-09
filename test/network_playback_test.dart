import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/network/network_http.dart';
import 'package:lazer_nextgen/network/network_library.dart';
import 'package:lazer_nextgen/network/network_source.dart';
import 'package:lazer_nextgen/network/network_sources_controller.dart';
import 'package:lazer_nextgen/network/podcast_feed.dart';
import 'package:lazer_nextgen/network/radio_station.dart';
import 'package:lazer_nextgen/network/remote_source.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine implements AudioEngine, BufferedAudioEngine {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final List<String> urls = <String>[];
  final List<Duration> seeks = <Duration>[];
  int playCalls = 0;
  @override
  bool active = false;
  Duration _position = Duration.zero;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => null;

  /// Zero means "nothing has landed yet": a source that waited for the startup
  /// buffer here would never start.
  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Future<void> setUrl(String url) async {
    urls.add(url);
    active = true;
    _position = Duration.zero;
  }

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {}

  void advance(Duration delta) {
    _position += delta;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _position = position;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  Stream<void> get completed => _completed.stream;

  @override
  void dispose() {
    _completed.close();
  }
}

class _Client implements RemoteSourceClient {
  @override
  NetworkSourceKind get kind => NetworkSourceKind.webdav;

  @override
  Future<RemoteListing> list(String path) async => RemoteListing(
    path: path,
    entries: <RemoteEntry>[
      RemoteEntry(
        name: 'song.flac',
        path: '$path/song.flac',
        isDirectory: false,
        size: 10,
      ),
    ],
  );

  @override
  Future<RemoteEntry?> stat(String path) async => RemoteEntry(
    name: path.split('/').last,
    path: path,
    isDirectory: false,
    size: 10,
  );

  @override
  Future<RemoteRead> open(String path, {int start = 0, int? end}) async =>
      RemoteRead.fromStream(
        Stream<List<int>>.value(const <int>[1, 2, 3]),
        totalBytes: 3,
      );

  @override
  Future<void> close() async {}
}

const String _feed = '''<rss version="2.0"><channel><title>Show</title>
<item><title>Ep</title><guid>ep-1</guid>
<pubDate>Mon, 06 May 2024 07:00:00 GMT</pubDate>
<enclosure url="http://a.example/1.mp3" type="audio/mpeg"/></item>
</channel></rss>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late NetworkSourcesController controller;
  late _Engine engine;
  late AppState state;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    directory = Directory.systemTemp.createTempSync('lazer-network-play');
    now = DateTime(2024, 5, 6, 7);
    controller = NetworkSourcesController(
      clock: () => now,
      supportDirectory: () async => directory,
      clientFactory: (RemoteSourceConnection connection) async => _Client(),
      textFetcher:
          (Uri uri, {Duration timeout = const Duration(seconds: 20)}) async =>
              NetworkText(body: _feed, uri: uri),
    );
    engine = _Engine();
    state = AppState(audioEngine: engine, networkSources: controller);
    await controller.load();
  });

  tearDown(() {
    state.dispose();
    engine.dispose();
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  test('a network track plays from the loopback gate', () async {
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(kind: NetworkSourceKind.webdav, host: 'nas.local'),
    );
    final NetworkTrackEntry entry = await controller.ensureEntry(
      source.id,
      RemoteEntry(
        name: 'song.flac',
        path: '/song.flac',
        isDirectory: false,
        size: 10,
      ),
    );
    state.playQueue(<Track>[entry.toTrack()]);
    await settle();
    expect(engine.urls, hasLength(1));
    expect(engine.urls.single, contains('/file/${source.id}/'));
    expect(engine.urls.single, startsWith('http://127.0.0.1:'));
    expect(state.current?.id, entry.id);
  });

  test('a live station starts immediately without the startup buffer', () async {
    final RadioStation station = await controller.addStation(
      name: 'Jazz',
      url: 'http://jazz.example/live',
    );
    state.playQueue(<Track>[station.toTrack()]);
    await settle();
    expect(engine.urls.single, contains('/relay/radio:${station.id}'));
    // Ten seconds of startup buffering would leave play() uncalled here.
    expect(engine.playCalls, greaterThan(0));
    expect(state.startupBuffering, isFalse);
    expect(controller.isLiveStream(station.toTrack()), isTrue);
  });

  test('podcast progress is saved while the tick lane runs', () async {
    final PodcastSubscription podcast = await controller.subscribe(
      'https://podcast.example/feed.xml',
    );
    final PodcastEpisode episode = podcast.episodes.single;
    // bootstrap() installs the playback listener on AppState.all, which is
    // where position ticks arrive.
    await state.bootstrap();
    state.playQueue(<Track>[podcastTrack(podcast, episode)]);
    await settle();
    engine.advance(const Duration(minutes: 3));
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (controller
              .progressForTrackId(podcastTrackIdOf(episode.id))
              .position >
          const Duration(minutes: 1)) {
        break;
      }
    }
    expect(
      controller.progressForTrackId(podcastTrackIdOf(episode.id)).position,
      greaterThan(const Duration(minutes: 1)),
    );
  });

  test('a podcast episode resumes at the saved position', () async {
    final PodcastSubscription podcast = await controller.subscribe(
      'https://podcast.example/feed.xml',
    );
    final PodcastEpisode episode = podcast.episodes.single;
    await controller.saveEpisodePosition(episode.id, const Duration(minutes: 2));
    state.playQueue(<Track>[podcastTrack(podcast, episode)]);
    await settle();
    expect(engine.urls.single, contains('/relay/podcast:${episode.id}'));
    await state.seekTo(const Duration(minutes: 2));
    expect(engine.seeks, contains(const Duration(minutes: 2)));
    expect(
      controller.progressForTrackId(state.current!.id).position,
      const Duration(minutes: 2),
    );
  });
}
