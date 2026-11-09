import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/network/credentials_vault.dart';
import 'package:lazer_nextgen/network/network_http.dart';
import 'package:lazer_nextgen/network/network_library.dart';
import 'package:lazer_nextgen/network/network_source.dart';
import 'package:lazer_nextgen/network/network_sources_controller.dart';
import 'package:lazer_nextgen/network/podcast_feed.dart';
import 'package:lazer_nextgen/network/radio_station.dart';
import 'package:lazer_nextgen/network/remote_source.dart';

class _MemoryClient implements RemoteSourceClient {
  _MemoryClient(this.kind);

  @override
  final NetworkSourceKind kind;

  final Map<String, List<String>> folders = <String, List<String>>{
    '/': <String>['Music'],
    '/Music': <String>['Album', 'a.flac', 'b.mp3', 'cover.jpg'],
    '/Music/Album': <String>['c.m4a'],
  };
  final Map<String, List<int>> files = <String, List<int>>{
    '/Music/a.flac': List<int>.generate(100, (int i) => i),
    '/Music/b.mp3': utf8.encode('bbbb'),
    '/Music/Album/c.m4a': utf8.encode('cccc'),
  };
  bool closed = false;
  int listCalls = 0;

  List<RemoteEntry> _entries(String path) {
    final List<String> names = folders[path] ?? const <String>[];
    return <RemoteEntry>[
      for (final String name in names)
        RemoteEntry(
          name: name,
          path: path == '/' ? '/$name' : '$path/$name',
          isDirectory: folders.containsKey(
            path == '/' ? '/$name' : '$path/$name',
          ),
          size: files[path == '/' ? '/$name' : '$path/$name']?.length,
        ),
    ];
  }

  @override
  Future<RemoteListing> list(String path) async {
    listCalls++;
    return RemoteListing(path: path, entries: _entries(path));
  }

  @override
  Future<RemoteEntry?> stat(String path) async {
    for (final RemoteEntry entry in _entries(remoteParent(path))) {
      if (entry.path == path) return entry;
    }
    return null;
  }

  @override
  Future<RemoteRead> open(String path, {int start = 0, int? end}) async {
    final List<int> data = files[path] ?? const <int>[];
    final int last = (end ?? (data.length - 1)).clamp(0, data.length - 1);
    return RemoteRead.fromStream(
      Stream<List<int>>.value(data.sublist(start, last + 1)),
      totalBytes: data.length,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _Ticker extends ChangeNotifier {
  void tick() => notifyListeners();
}

Future<NetworkSourcesController> _controller(
  Directory directory, {
  Map<String, String>? passwords,
  Map<String, _MemoryClient>? clients,
  String? feed,
  String? playlist,
  DateTime Function()? clock,
  int maxScanFiles = 20000,
}) async {
  Future<NetworkText> fetcher(
    Uri uri, {
    Duration timeout = const Duration(seconds: 20),
  }) async => NetworkText(body: feed ?? playlist ?? '', uri: uri);
  final Map<String, _MemoryClient> pool = clients ?? <String, _MemoryClient>{};
  return NetworkSourcesController(
    vault: NetworkCredentialsVault(supportDirectory: () async => directory),
    supportDirectory: () async => directory,
    clientFactory: (RemoteSourceConnection connection) async {
      passwords?[connection.host] = connection.password;
      return pool.putIfAbsent(
        connection.host,
        () => _MemoryClient(connection.kind),
      );
    },
    textFetcher: fetcher,
    clock: clock,
    maxScanFiles: maxScanFiles,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('lazer-network-test');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a source and its password survive a restart', () async {
    final Map<String, String> passwords = <String, String>{};
    final NetworkSourcesController first = await _controller(
      directory,
      passwords: passwords,
    );
    addTearDown(first.dispose);
    await first.load();
    expect(first.loaded, isTrue);
    final NetworkSource source = await first.addSource(
      NetworkSourceDraft(
        kind: NetworkSourceKind.webdav,
        name: 'NAS',
        host: 'nas.local',
        port: 8080,
        path: '/music',
        username: 'user',
        password: 'secret',
      ),
    );
    expect(source.displayName, 'NAS');

    final NetworkSourcesController second = await _controller(
      directory,
      passwords: passwords,
    );
    addTearDown(second.dispose);
    await second.load();
    expect(second.sources.length, 1);
    expect(second.sources.single.path, '/music');
    expect(second.sources.single.username, 'user');

    // The stored secret is loaded and handed to the adapter.
    await second.list(source.id, '/');
    expect(passwords['nas.local'], 'secret');

    final File vault = File('${directory.path}/network_credentials.json');
    expect(await vault.exists(), isTrue);
    expect(await vault.readAsString(), isNot(contains('secret')));
  });

  test('an empty password field keeps the stored secret, clear drops it', () async {
    final Map<String, String> passwords = <String, String>{};
    final NetworkSourcesController controller = await _controller(
      directory,
      passwords: passwords,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(
        kind: NetworkSourceKind.ftp,
        host: 'nas.local',
        password: 'secret',
      ),
    );
    await controller.updateSource(
      source.id,
      NetworkSourceDraft.fromSource(source),
    );
    await controller.list(source.id, '/');
    expect(passwords['nas.local'], 'secret');
    await controller.updateSource(
      source.id,
      NetworkSourceDraft.fromSource(source),
      clearPassword: true,
    );
    await controller.disconnect(source.id);
    await controller.list(source.id, '/');
    expect(passwords['nas.local'], '');
  });

  test('removing a source drops its credentials and indexed tracks', () async {
    final NetworkSourcesController controller = await _controller(directory);
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(
        kind: NetworkSourceKind.sftp,
        host: 'nas.local',
        path: '/',
        password: 'secret',
      ),
    );
    await controller.scan(source.id, '/Music');
    expect(controller.entries, isNotEmpty);
    await controller.removeSource(source.id);
    expect(controller.sources, isEmpty);
    expect(controller.entries, isEmpty);
  });

  test('scan indexes audio files once and reports the pass', () async {
    final Map<String, _MemoryClient> clients = <String, _MemoryClient>{};
    final NetworkSourcesController controller = await _controller(
      directory,
      clients: clients,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(
        kind: NetworkSourceKind.webdav,
        host: 'nas.local',
        path: '/',
      ),
    );
    final NetworkScanResult first = await controller.scan(source.id, '/Music');
    expect(first.added, 3);
    expect(first.failed, 0);
    expect(controller.entries.length, 3);
    expect(
      controller.entries.map((NetworkTrackEntry entry) => entry.path).toSet(),
      <String>{'/Music/a.flac', '/Music/b.mp3', '/Music/Album/c.m4a'},
    );
    expect(controller.libraryTracks.length, 3);
    expect(controller.entriesFor(source.id).length, 3);

    final NetworkScanResult second = await controller.scan(source.id, '/Music');
    expect(second.added, 0);
    expect(second.updated, 3);
    expect(controller.entries.length, 3);
  });

  test('the file cap stops the folder walk instead of only the inner loop',
      () async {
    final _MemoryClient client = _MemoryClient(NetworkSourceKind.webdav);
    client.folders
      ..clear()
      ..addAll(<String, List<String>>{
        '/': <String>['A', 'B'],
        '/A': <String>['1.flac', '2.flac', '3.flac'],
        '/B': <String>['4.flac'],
      });
    final Map<String, _MemoryClient> clients = <String, _MemoryClient>{
      'nas.local': client,
    };
    final NetworkSourcesController controller = await _controller(
      directory,
      clients: clients,
      maxScanFiles: 2,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(
        kind: NetworkSourceKind.webdav,
        host: 'nas.local',
      ),
    );
    final NetworkScanResult result = await controller.scan(source.id, '/');
    expect(result.added, 2);
    expect(result.cancelled, isTrue);
    // Root and A were listed; B was never reached once the cap was hit.
    expect(client.listCalls, 2);
  });

  test('a scan notifies once per folder, not once per indexed file', () async {
    final _MemoryClient client = _MemoryClient(NetworkSourceKind.webdav);
    client.folders
      ..clear()
      ..addAll(<String, List<String>>{
        '/': <String>['A'],
        '/A': <String>[for (var i = 0; i < 30; i++) 'track$i.flac'],
      });
    final NetworkSourcesController controller = await _controller(
      directory,
      clients: <String, _MemoryClient>{'nas.local': client},
    );
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(kind: NetworkSourceKind.webdav, host: 'nas.local'),
    );
    int notifications = 0;
    controller.addListener(() => notifications++);
    final NetworkScanResult result = await controller.scan(source.id, '/');
    expect(result.added, 30);
    // Start, two per listed folder (folder label + finished folder) and the
    // final scan-state change — not one per file.
    expect(notifications, lessThanOrEqualTo(6));
    expect(controller.countFor(source.id), 30);
  });

  test('scan can be cancelled between folders', () async {
    final NetworkSourcesController controller = await _controller(directory);
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(
        kind: NetworkSourceKind.webdav,
        host: 'nas.local',
      ),
    );
    final NetworkScanCancel cancel = NetworkScanCancel();
    final Future<NetworkScanResult> running = controller.scan(
      source.id,
      '/Music',
      cancel: cancel,
    );
    cancel.cancel();
    final NetworkScanResult result = await running;
    expect(result.cancelled, isTrue);
    expect(controller.scanning, isFalse);
  });

  test('a podcast enclosure cannot make the gate read this machine', () async {
    const String feed = '<rss version="2.0"><channel><title>Local</title>'
        '<item><title>X</title><guid>g1</guid>'
        '<enclosure url="http://127.0.0.1:9/x.mp3" type="audio/mpeg"/>'
        '</item></channel></rss>';
    final NetworkSourcesController controller = await _controller(
      directory,
      feed: feed,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final PodcastSubscription podcast = await controller.subscribe(
      'https://podcast.example/feed.xml',
    );
    final String? url = await controller.resolveStream(
      podcastTrack(podcast, podcast.episodes.single),
    );
    expect(url, isNotNull);
    // The widget-test binding installs an HttpClient that answers 400; this
    // test needs the real loopback gate.
    HttpOverrides.global = null;
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientResponse response = await (await client.getUrl(
      Uri.parse(url!),
    )).close();
    expect(response.statusCode, HttpStatus.notFound);
    await response.drain<void>();
  });

  test('streams resolve through the loopback gate', () async {
    final Map<String, _MemoryClient> clients = <String, _MemoryClient>{};
    final NetworkSourcesController controller = await _controller(
      directory,
      clients: clients,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(
        kind: NetworkSourceKind.smb,
        host: 'nas.local',
        path: 'Music',
      ),
    );
    await controller.scan(source.id, '/');
    final NetworkTrackEntry entry = controller.entries.first;
    final String? url = await controller.resolveStream(entry.toTrack());
    expect(url, isNotNull);
    expect(url!, startsWith('http://127.0.0.1:'));
    final Uri parsed = Uri.parse(url);
    expect(parsed.pathSegments[1], 'file');
    expect(parsed.pathSegments[2], source.id);
    expect(parsed.pathSegments.last, entry.path.split('/').last);

    final RadioStation station = await controller.addStation(
      name: 'Jazz',
      url: 'http://jazz.example/live',
    );
    final String? radioUrl = await controller.resolveStream(station.toTrack());
    expect(radioUrl, contains('/relay/radio:${station.id}'));

    expect(await controller.resolveStream(const Track(
      id: 'network:unknown',
      title: 'x',
      artist: 'x',
      album: 'x',
      duration: Duration.zero,
      coverSeed: 0,
    )), isNull);
    expect(controller.ownsTrackId('radio:1'), isTrue);
    expect(controller.ownsTrackId('42'), isFalse);
  });

  test('radio stations and playlist imports are persisted', () async {
    final NetworkSourcesController controller = await _controller(
      directory,
      playlist: '#EXTM3U\n#EXTINF:-1,News\n/news.m3u8\n'
          '#EXTINF:-1,Jazz\nhttp://jazz.example/live\n',
    );
    addTearDown(controller.dispose);
    await controller.load();
    final RadioStation station = await controller.addStation(
      name: 'Jazz',
      url: 'http://jazz.example/live',
      genre: 'Jazz',
    );
    expect(controller.stations.length, 1);
    await controller.updateStation(station.id, name: 'Jazz FM');
    expect(controller.stationById(station.id)!.name, 'Jazz FM');

    final int added = await controller.importRadioPlaylist(
      Uri.parse('http://list.example/radio.m3u'),
    );
    // The relative entry is resolved and added; the absolute one is already a
    // station, so the import leaves it alone.
    expect(added, 1);
    expect(controller.stations.length, 2);
    expect(
      controller.stations.any(
        (RadioStation station) => station.url == 'http://list.example/news.m3u8',
      ),
      isTrue,
    );
    final int again = await controller.importRadioPlaylist(
      Uri.parse('http://list.example/radio.m3u'),
    );
    expect(again, 0);

    await controller.removeStation(station.id);
    expect(controller.stationById(station.id), isNull);
  });

  test('podcast subscriptions parse, refresh and keep progress', () async {
    const String feed = '''<?xml version="1.0"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Night Show</title>
    <description>Talk</description>
    <itunes:image href="http://img.example/cover.jpg"/>
    <item>
      <title>Episode One</title>
      <guid>ep-1</guid>
      <pubDate>Mon, 06 May 2024 07:08:09 GMT</pubDate>
      <itunes:duration>1:02:03</itunes:duration>
      <enclosure url="http://a.example/1.mp3" length="1234" type="audio/mpeg"/>
    </item>
    <item>
      <title>Episode Two</title>
      <guid>ep-2</guid>
      <enclosure url="http://a.example/2.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>''';
    final NetworkSourcesController controller = await _controller(
      directory,
      feed: feed,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final PodcastSubscription subscription = await controller.subscribe(
      'podcast.example/feed.xml',
    );
    expect(subscription.feedUrl, 'https://podcast.example/feed.xml');
    expect(subscription.episodes.length, 2);
    expect(subscription.episodes.first.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(subscription.imageUrl, 'http://img.example/cover.jpg');

    final PodcastEpisode episode = subscription.episodes.first;
    await controller.saveEpisodePosition(episode.id, const Duration(minutes: 5));
    expect(
      controller.progressForTrackId(podcastTrackIdOf(episode.id)).position,
      const Duration(minutes: 5),
    );
    final PodcastSubscription refreshed = await controller.refreshPodcast(
      subscription.id,
    );
    expect(refreshed.episodes.length, 2);
    expect(
      refreshed.progressOf(episode.id).position,
      const Duration(minutes: 5),
    );

    await controller.markEpisodePlayed(episode.id);
    expect(controller.progressForTrackId(podcastTrackIdOf(episode.id)).played, isTrue);
    await controller.clearEpisodeProgress(episode.id);
    expect(controller.progressForTrackId(podcastTrackIdOf(episode.id)).played, isFalse);

    final String? url = await controller.resolveStream(
      podcastTrack(subscription, episode),
    );
    expect(url, contains('/relay/podcast:${episode.id}'));

    final ({int refreshed, int failed}) refreshedAll =
        await controller.refreshAllPodcasts();
    expect(refreshedAll.refreshed, 1);
    expect(refreshedAll.failed, 0);
    await controller.unsubscribe(subscription.id);
    expect(controller.podcasts, isEmpty);
  });

  test('a broken feed is reported and stored on the model', () async {
    final NetworkSourcesController controller = await _controller(
      directory,
      feed: '<html>not a feed</html>',
    );
    addTearDown(controller.dispose);
    await controller.load();
    await expectLater(
      controller.subscribe('https://podcast.example/feed.xml'),
      throwsA(isA<PodcastFeedException>()),
    );
    expect(controller.podcasts, isEmpty);
  });

  test('playback ticks save the podcast position at most every ten seconds', () async {
    const String feed = '''<rss version="2.0"><channel><title>Show</title>
      <item><title>Ep</title><guid>ep-1</guid>
      <enclosure url="http://a.example/1.mp3" type="audio/mpeg"/></item>
      </channel></rss>''';
    final DateTime start = DateTime(2024, 5, 6, 7);
    DateTime now = start;
    final NetworkSourcesController controller = await _controller(
      directory,
      feed: feed,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final PodcastSubscription subscription = await controller.subscribe(
      'https://podcast.example/feed.xml',
    );
    final PodcastEpisode episode = subscription.episodes.first;
    final Track track = podcastTrack(subscription, episode);
    final _Ticker ticker = _Ticker();
    addTearDown(ticker.dispose);
    Duration position = const Duration(seconds: 30);
    controller.attachPlayback(
      current: () => track,
      position: () => position,
      listenable: ticker,
    );
    ticker.tick();
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.progressForTrackId(track.id).position,
      const Duration(seconds: 30),
    );
    position = const Duration(seconds: 40);
    ticker.tick();
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.progressForTrackId(track.id).position,
      const Duration(seconds: 30),
      reason: 'the throttle keeps the first save',
    );
    now = now.add(const Duration(seconds: 11));
    ticker.tick();
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.progressForTrackId(track.id).position,
      const Duration(seconds: 40),
    );
    controller.detachPlayback();
  });

  test('a scan pass refuses a second one while it runs', () async {
    final NetworkSourcesController controller = await _controller(directory);
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(kind: NetworkSourceKind.webdav, host: 'nas.local'),
    );
    final NetworkScanCancel cancel = NetworkScanCancel();
    final Future<NetworkScanResult> first = controller.scan(
      source.id,
      '/Music',
      cancel: cancel,
    );
    await expectLater(
      controller.scan(source.id, '/Music'),
      throwsA(isA<RemoteFailure>()),
    );
    cancel.cancel();
    await first;
  });

  test('track ids cannot escape the configured source', () async {
    final NetworkSourcesController controller = await _controller(directory);
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(kind: NetworkSourceKind.webdav, host: 'nas.local'),
    );
    await controller.scan(source.id, '/Music');
    final NetworkTrackEntry entry = controller.entries.first;
    final Track forged = entry.toTrack();
    final String url = (await controller.resolveStream(forged))!;
    // The gate re-normalises the path it receives; a traversal cannot leave the
    // source because the adapter always resolves against its configured root.
    expect(remoteNormalize('/../../etc/passwd'), '/etc/passwd');
    expect(url, contains(entry.path));
  });

  test('indexed tracks survive a restart', () async {
    final NetworkSourcesController first = await _controller(directory);
    addTearDown(first.dispose);
    await first.load();
    final NetworkSource source = await first.addSource(
      NetworkSourceDraft(kind: NetworkSourceKind.webdav, host: 'nas.local'),
    );
    await first.scan(source.id, '/Music');

    final NetworkSourcesController second = await _controller(directory);
    addTearDown(second.dispose);
    await second.load();
    expect(second.entries.length, 3);
    expect(second.entriesFor(source.id).length, 3);
    expect(second.libraryTracks.first.album, isNotEmpty);
  });

  test('removing one indexed track leaves the rest', () async {
    final NetworkSourcesController controller = await _controller(directory);
    addTearDown(controller.dispose);
    await controller.load();
    final NetworkSource source = await controller.addSource(
      NetworkSourceDraft(kind: NetworkSourceKind.webdav, host: 'nas.local'),
    );
    await controller.scan(source.id, '/Music');
    final NetworkTrackEntry entry = controller.entries.first;
    await controller.removeEntry(entry.id);
    expect(controller.entries.length, 2);
    await controller.clearSourceEntries(source.id);
    expect(controller.entries, isEmpty);
  });
}
