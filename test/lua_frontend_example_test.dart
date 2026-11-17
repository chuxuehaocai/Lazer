import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';

Future<Uint8List> _examplePackage() async {
  final archive = Archive();
  final directory = Directory('examples/lua-frontend');
  await for (final file in directory.list(recursive: true)) {
    if (file is! File) continue;
    final name = file.path
        .substring(directory.path.length + 1)
        .replaceAll(r'\', '/');
    var content = await file.readAsBytes();
    // Production uses an explicit fixed port; tests request a manifest-declared
    // ephemeral port to be independent of other running tests or applications.
    if (name == 'manifest.json') {
      final manifest = jsonDecode(utf8.decode(content)) as Map;
      (manifest['permissions'] as Map)['websocketServer'] = ['127.0.0.1:0'];
      content = utf8.encode(jsonEncode(manifest));
    } else if (name == 'bridge.json') {
      content = utf8.encode('{"port":0}');
    }
    archive.addFile(ArchiveFile(name, content.length, content));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'standalone JS frontend drives the Lua bridge and real backend with scoped consent',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'lazer-browser-bridge-',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      final plugins = PluginManager(
        rootDirectory: Directory('${directory.path}/plugins'),
      );
      final engine = _Engine();
      final catalog = _Catalog();
      final state = AppState(
        catalog: catalog,
        pluginManager: plugins,
        audioEngine: engine,
        artworkSeedLoader: (_) async => null,
        listeningStatistics: ListeningStatisticsController(
          read: () async => null,
          write: (_) async {},
        ),
      );
      final allow = <String>{'websocketServer'};
      final prompts = <String>[];
      plugins.onPermissionRequest = (_, scope) async {
        prompts.add(scope);
        return allow.contains(scope);
      };
      Process? node;
      StreamIterator<String>? replies;
      addTearDown(() async {
        node?.stdin.close();
        node?.kill();
        await replies?.cancel();
        state.dispose();
        await plugins.shutdownSettled;
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await directory.delete(recursive: true);
      });
      final plugin = await plugins.importZip(await _examplePackage());
      expect(plugin.error, isNull);
      await plugins.invokePluginSetting('example.frontend', 'start');
      Object? field(String id) => plugins.pluginPages.single.elements
          .firstWhere((element) => element.id == id)
          .value;
      final url = field('url') as String;
      final token = field('token') as String;
      expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
      // Node >= 22 provides the same WebSocket API used by the browser. Tokens
      // travel over stdin, never in process arguments or test output.
      node = await Process.start('node', [
        'test/fixtures/lua_frontend_client.cjs',
      ]);
      final stderr = <String>[];
      node.stderr.transform(utf8.decoder).listen(stderr.add);
      replies = StreamIterator(
        node.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      Future<Map> send(Map<String, Object?> command) async {
        node!.stdin.writeln(jsonEncode(command));
        expect(
          await replies!.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
          reason: stderr.join(),
        );
        return jsonDecode(replies!.current) as Map;
      }

      Future<Object?> request(
        String method, [
        Map<String, Object?> args = const {},
      ]) async {
        final result = await send({'method': method, 'args': args});
        expect(result['ok'], true, reason: '${result['error']}');
        return result['value'];
      }

      expect(
        (await send({
          'operation': 'connect',
          'url': url,
          'token': 'wrong',
        }))['ok'],
        false,
      );
      final authenticated = await send({
        'operation': 'connect',
        'url': url,
        'token': token,
      });
      expect(authenticated['ok'], true, reason: '${authenticated['error']}');
      // No playback or player_event is required to serve the browser.
      expect((await request('state') as Map)['state'], 'paused');
      expect((await request('queue') as Map)['length'], 0);
      final emptyUi = await send({
        'operation': 'render',
        'url': url,
        'token': token,
      });
      expect(emptyUi['ok'], true, reason: '${emptyUi['error']}');
      expect(emptyUi['value'], {
        'title': '暂未播放',
        'queueRows': 0,
        'lyricRows': 0,
        'time': '0:00 / 0:00',
      });
      expect(prompts, ['websocketServer']);
      final denied = await send({
        'method': 'library',
        'args': {'operation': 'tracks', 'id': 'private-list'},
      });
      expect(denied['ok'], false);
      expect(catalog.playlistReads, 0);
      allow.add('data.library');
      final page =
          await request('library', {
                'operation': 'tracks',
                'id': 'private-list',
              })
              as Map;
      expect((page['items'] as List).single['title'], 'Bridge song');
      expect(jsonEncode(page), isNot(contains('/private/')));
      final lists = await request('library', {'operation': 'playlists'}) as Map;
      expect((lists['items'] as List).single['id'], 'private-list');
      expect(
        await request('library', {'operation': 'play', 'id': 'private-list'}),
        true,
      );
      final queue = await request('queue') as Map;
      expect((queue['tracks'] as List).single['title'], 'Bridge song');
      expect(engine.urls, isNotEmpty);
      await request('player', {'command': 'pause'});
      expect(state.playing, false);
      await request('player', {'command': 'volume', 'value': 0.35});
      expect(state.volume, closeTo(0.35, 0.001));
      await request('player', {'command': 'seek', 'fraction': 0.5});
      expect(engine.position, const Duration(seconds: 90));
      final lyrics = await request('lyrics') as Map;
      expect((lyrics['lines'] as List).single['text'], 'Bridge lyric');
      final playingUi = await send({
        'operation': 'render',
        'url': url,
        'token': token,
      });
      expect(playingUi['ok'], true, reason: '${playingUi['error']}');
      expect((playingUi['value'] as Map)['title'], 'Bridge song');
      expect((playingUi['value'] as Map)['queueRows'], 1);
      expect((playingUi['value'] as Map)['lyricRows'], 1);
      // The RPC whitelist cannot become an arbitrary host-control gateway.
      expect(
        (await send({
          'method': 'player',
          'args': {'command': 'user_profile'},
        }))['ok'],
        false,
      );
      expect(
        (await send({
          'method': 'user',
          'args': {'operation': 'profile'},
        }))['ok'],
        false,
      );
      allow.add('data.profile');
      final profile = await request('user', {'operation': 'profile'}) as Map;
      expect((profile['accounts'] as List).single['id'], 'listener-id');
      expect(jsonEncode(profile), isNot(contains('secret-cookie')));
      expect(await request('user', {'operation': 'platforms'}), isA<List>());
      expect(
        (await send({
          'method': 'user',
          'args': {'operation': 'statistics'},
        }))['ok'],
        false,
      );
      allow.add('data.history');
      expect(
        (await request('user', {'operation': 'statistics'})
            as Map)['playCount'],
        isA<int>(),
      );
      await plugins.setDataPermission('example.frontend', 'library', false);
      allow.remove('data.library');
      final previousReads = catalog.playlistReads;
      expect(
        (await send({
          'method': 'library',
          'args': {'operation': 'tracks', 'id': 'private-list'},
        }))['ok'],
        false,
      );
      expect(catalog.playlistReads, previousReads);
      expect(
        (await request('permissions') as Map)['granted'],
        isNot(contains('library')),
      );
      await plugins.invokePluginSetting('example.frontend', 'stop');
      expect(field('token'), '');
      await plugins.invokePluginSetting('example.frontend', 'start');
      expect(field('token'), isNot(token));
      expect(
        (await send({
          'operation': 'connect',
          'url': field('url'),
          'token': token,
        }))['ok'],
        false,
      );
      final port = Uri.parse(field('url') as String).port;
      await plugins.setEnabled('example.frontend', false);
      final listener = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await listener.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

const _track = Track(
  id: 'bridge-song',
  title: 'Bridge song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
  coverUrl: 'file:///private/cover.png',
);

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  int playlistReads = 0;
  @override
  Future<List<Track>> playlistTracks(String id) async {
    playlistReads++;
    return [_track];
  }

  @override
  Future<UserCollections> userCollections(int uid) async =>
      const UserCollections(
        created: [
          Playlist(
            id: 'private-list',
            name: 'My collection',
            description: '',
            trackCount: 1,
            trackIds: ['bridge-song'],
            coverSeed: 1,
          ),
        ],
      );
  @override
  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
    bool Function()? isCancelled,
  }) async => AudioSource(url: 'fixture://audio', quality: quality);
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]Bridge lyric');
}

class _Gateway extends MusicGateway {
  final cookie = 'secret-cookie';
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
  @override
  String get connectionId => 'fixture';
  @override
  Set<MusicCapability> get capabilities => {};
  @override
  MusicUser get user =>
      MusicUser(id: id(MusicEntityKind.user, 'listener-id'), name: 'Listener');
}

class _Engine implements AudioEngine {
  final urls = <String>[];
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => _track.duration;
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setUrl(String url) async {
    urls.add(url);
    active = true;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  void dispose() {}
}
