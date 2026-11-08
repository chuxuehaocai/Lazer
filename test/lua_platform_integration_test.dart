import 'package:lazer_nextgen/lyrics/cached_lyrics_store.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/audio/hifi_controller.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/login.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section.dart';

const _source = '''
local pending = {}
return {call=function(op, args)
  local platform = args.platform or "alpha"
  local key = "session_" .. platform
  if op == "describe" then return {providers={
    {id="alpha",name="Alpha Music",auth={"cookie"},capabilities={}},
    {id="beta",name="Beta Radio",auth={"qr"},capabilities={}}
  }} end
  if op == "session" then
    if pending[platform] then pending[platform]=nil; return nil end
    if not host.storage_get(key) then return nil end
    return {id=platform.."-user",name=platform.." listener"}
  end
  if op == "loginCookie" then
    if args.cookie == "invalid" then return nil end
    host.storage_set(key,args.cookie)
    return {id=platform.."-user",name=platform.." listener"}
  end
  if op == "logout" then host.storage_set(key,nil); return true end
  if op == "qrKey" then return "opaque-token" end
  if op == "qrUrl" then return "https://radio.test/connect?token="..args.key end
  if op == "qrCheck" then
    if args.key ~= "opaque-token" then error("incorrect QR token") end
    host.storage_set(key,"fixture-qr-session")
    pending[platform]=true
    return 803
  end
  return {}
end}
''';

final _musicSource = _source
    .replaceAll(
      'capabilities={}',
      'capabilities={"playlists","favorites","lyrics","scrobble"}',
    )
    .replaceFirst('  return {}', '''
  local function song() return {id=platform.."-song",title=platform.." song",artists={},durationMs=180000} end
  if op == "playlists" then return {{id=platform.."-favorites",name=platform.." listener喜欢的音乐",writable=true,isFavorites=true,songCount=1}} end
  if op == "favorites" then return host.storage_get("star_"..platform) and {song()} or {} end
  if op == "playlistSongs" then return host.storage_get("star_"..platform) and {song()} or {} end
  if op == "song" then return song() end
  if op == "setFavorite" then host.storage_set("star_"..platform,args.favorite); return true end
  if op == "stream" then return {url="https://fixture.invalid/"..platform.."/audio.flac",suffix="flac"} end
  if op == "scrobble" then host.storage_set("reports_"..platform,(host.storage_get("reports_"..platform) or 0)+1); return true end
  if op == "testState" then return {starred=host.storage_get("star_"..platform) or false,reports=host.storage_get("reports_"..platform) or 0} end
  return {}
''');

CachedLyricsStore _noLyricsDisk() => CachedLyricsStore(supportDirectory:()async=>throw const FileSystemException('lyrics tested separately'));
Catalog _isolatedCatalog() => Catalog(cache:DiskCache(directory:()async=>throw const FileSystemException('catalogue tested separately')),lyricsCache:_noLyricsDisk());
class _MusicCatalog extends Catalog {
  _MusicCatalog(Directory directory)
    : super(cache: DiskCache(directory: () async => directory),lyricsCache:_noLyricsDisk());
  @override
  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
  }) => super.audioSourceFor(track, quality: quality, useCache: false);
}

class _Engine implements AudioEngine {
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<void> get completed => const Stream.empty();
  final urls = <String>[];
  int stops = 0;
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
  Future<void> seek(Duration next) async {
    position = next;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {
    active = false;
    stops++;
  }

  @override
  void dispose() {}
}

Future<void> _waitFor(bool Function() completed) async {
  final deadline = Stopwatch()..start();
  while (!completed() && deadline.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(completed(), isTrue);
}

Uint8List _package({String source = _source, String version = '1.0.0'}) {
  final files = {
    'manifest.json': jsonEncode({
      'id': 'fixture.multiple',
      'name': 'Fixture plugin',
      'version': version,
      'provider': 'manifest_fallback',
      'apiVersion': 1,
      'permissions': {'storage': true},
    }),
    'main.lua': source,
  };
  final archive = Archive();
  for (final file in files.entries) {
    final bytes = utf8.encode(file.value);
    archive.addFile(ArchiveFile(file.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('lazer-lua-platforms-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });
  PluginManager manager() =>
      PluginManager(rootDirectory: Directory('${directory.path}/plugins'));
  AppState state(PluginManager plugins) =>
      AppState(catalog:_isolatedCatalog(),pluginManager: plugins, artworkSeedLoader: (_) async => null);

  test('Lua description supplies platforms and login capabilities', () async {
    final plugins = manager();
    await plugins.importZip(_package());
    final app = state(plugins);
    try {
      await app.bootstrap();
      expect(app.availableMusicPlatforms.map((g) => g.provider.id), [
        'local',
        'alpha',
        'beta',
      ]);
      expect(app.musicProvider.name, 'Alpha Music');
      expect(app.musicAuthenticationMethods, {'cookie'});
      final beta = plugins.gateways.last;
      await app.selectMusicConnection(GatewayRegistry.keyOf(beta));
      expect(app.musicProvider.name, 'Beta Radio');
      expect(app.musicAuthenticationMethods, {'qr'});
    } finally {
      app.dispose();
    }
  });

  test(
    'plugin import activates immediately; sessions and selection survive restart',
    () async {
      final plugins = manager();
      final app = state(plugins);
      await app.bootstrap();
      expect(app.musicProvider.id, 'local');
      await plugins.importZip(_package());
      expect(app.musicProvider.id, 'alpha');
      expect((await app.signInWithCookie('fixture-session')).ok, isTrue);
      final account = app.user.handle;
      expect((await app.signInWithCookie('invalid')).ok, isFalse);
      expect(app.user.handle, account);
      await app.selectMusicConnection('local:local');
      expect(
        app.isGuest,
        isFalse,
        reason: 'switching the content source must not sign out the account',
      );
      expect(app.user.name, 'alpha listener');
      await app.selectMusicConnection('alpha:fixture.multiple');
      expect(app.user.name, 'alpha listener');
      app.dispose();

      final restored = state(manager());
      try {
        await restored.bootstrap();
        expect(restored.activeConnectionKey, 'alpha:fixture.multiple');
        expect(restored.user.name, 'alpha listener');
        expect(restored.isGuest, isFalse);
        await restored.signOut();
      } finally {
        restored.dispose();
      }
      final signedOut = state(manager());
      try {
        await signedOut.bootstrap();
        expect(signedOut.isGuest, isTrue);
      } finally {
        signedOut.dispose();
      }
    },
  );

  test(
    'two platform sessions survive local selection, restart, and a scoped logout',
    () async {
      final plugins = manager();
      await plugins.importZip(_package(source: _musicSource));
      final app = state(plugins);
      await app.bootstrap();
      await app.signInWithCookie('alpha-fixture');
      await app.selectMusicConnection('beta:fixture.multiple');
      await app.signInWithCookie('beta-fixture');
      await app.selectMusicConnection('local:local');
      expect(
        app.musicAccounts.keys,
        containsAll(['alpha:fixture.multiple', 'beta:fixture.multiple']),
      );
      expect(app.user.name, 'beta listener');
      expect(app.signedIn, isTrue);
      expect(app.activeMusicSignedIn, isFalse);
      await expectLater(
        app.createCloudPlaylist('local must not create a cloud list'),
        throwsStateError,
      );
      app.dispose();
      final restored = state(manager());
      try {
        await restored.bootstrap();
        expect(restored.activeConnectionKey, 'local:local');
        expect(restored.user.name, 'beta listener');
        expect(restored.musicAccounts, hasLength(2));
        await restored.signOut(connectionKey: 'alpha:fixture.multiple');
        expect(restored.musicAccounts.keys, ['beta:fixture.multiple']);
        expect(restored.user.name, 'beta listener');
        await restored.selectMusicConnection('alpha:fixture.multiple');
        expect(restored.activeMusicSignedIn, isFalse);
        expect(restored.musicAccounts.keys, ['beta:fixture.multiple']);
        await restored.selectMusicConnection('beta:fixture.multiple');
        expect(restored.activeMusicSignedIn, isTrue);
      } finally {
        restored.dispose();
      }
    },
  );

  test(
    'restored Lua records recover covers without playing either platform',
    () async {
      final plugins = manager();
      await plugins.importZip(
        _package(
          source: _musicSource.replaceFirst(
            'artists={},durationMs=180000}',
            'artists={},durationMs=180000,coverUrl="https://images.test/"..platform..".jpg"}',
          ),
        ),
      );
      final first = state(plugins);
      await first.bootstrap();
      await first.signInWithCookie('alpha-fixture');
      await first.selectMusicConnection('beta:fixture.multiple');
      await first.signInWithCookie('beta-fixture');
      final tracks = [
        for (final gateway in plugins.gateways)
          Track(
            id: gateway
                .id(MusicEntityKind.song, '${gateway.provider.id}-song')
                .cacheKey,
            title: '${gateway.provider.id} cached title',
            artist: 'Cached artist',
            album: 'Cached album',
            translatedTitle: 'Cached translation',
            duration: const Duration(minutes: 3),
            coverSeed: 7,
          ),
      ];
      first.dispose();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        playbackQueueKey,
        jsonEncode({
          'index': 1,
          'tracks': tracks.map((track) => track.toJson()).toList(),
        }),
      );
      await prefs.setString(
        'lazer_recent_tracks_v1',
        jsonEncode(tracks.map((track) => track.toJson()).toList()),
      );
      final engine = _Engine();
      final restored = AppState(
        pluginManager: manager(),
        catalog:_isolatedCatalog(),
        audioEngine: engine,
        artworkSeedLoader: (_) async => null,
      );
      try {
        await restored.bootstrap();
        await _waitFor(
          () =>
              restored.recentTracks.length == 2 &&
              restored.recentTracks.every((track) => track.coverUrl != null),
        );
        expect(restored.recentTracks.map((track) => track.coverUrl), [
          'https://images.test/alpha.jpg',
          'https://images.test/beta.jpg',
        ]);
        expect(
          restored.queue.map((track) => track.id),
          tracks.map((track) => track.id),
        );
        expect(restored.current!.id, tracks.last.id);
        expect(restored.current!.coverUrl, 'https://images.test/beta.jpg');
        expect(
          restored.recentTracks.first.translatedTitle,
          'Cached translation',
        );
        expect(restored.recentTracks.first.artist, 'Cached artist');
        expect(restored.playing, isFalse);
        expect(engine.urls, isEmpty);
        await _waitFor(
          () => prefs
              .getString('lazer_recent_tracks_v1')!
              .contains('https://images.test/alpha.jpg'),
        );
      } finally {
        await restored.currentArtwork.ready;
        restored.dispose();
      }
    },
  );

  test(
    'mixed platform and local queues keep their owners through source changes',
    () async {
      final plugins = manager();
      await plugins.importZip(_package(source: _musicSource));
      final engine = _Engine();
      final app = AppState(
        pluginManager: plugins,
        catalog: _MusicCatalog(Directory('${directory.path}/catalog')),
        localLibrary: LocalLibrary(
          supportDirectory: () async =>
              throw const FileSystemException('disabled'),
          documentsDirectory: () async => directory,
        ),
        audioEngine: engine,
        artworkSeedLoader: (_) async => null,
      );
      try {
        await app.bootstrap();
        await app.signInWithCookie('alpha-fixture');
        await app.refreshCollections();
        final alpha = plugins.gateways.first as LuaMusicGateway;
        final alphaTrack = app.catalog.trackFromMusicSong(
          await alpha.song(alpha.id(MusicEntityKind.song, 'alpha-song')),
        );
        await app.selectMusicConnection('beta:fixture.multiple');
        await app.signInWithCookie('beta-fixture');
        await app.refreshCollections();
        final beta = plugins.gateways.last as LuaMusicGateway;
        final betaTrack = app.catalog.trackFromMusicSong(
          await beta.song(beta.id(MusicEntityKind.song, 'beta-song')),
        );
        final file = await File(
          '${directory.path}/local.flac',
        ).writeAsBytes([1, 2, 3]);
        final local = Track(
          id: 'local-fixture',
          title: 'Local song',
          artist: '',
          album: '',
          duration: const Duration(minutes: 3),
          coverSeed: 0,
          localPath: file.path,
        );
        await app.localLibrary.addTracks([
          LocalTrack(
            track: local,
            path: file.path,
            source: LocalTrackSource.scan,
            modifiedAt: DateTime.now(),
            addedAt: DateTime.now(),
          ),
        ]);
        app.playQueue([alphaTrack, betaTrack, local]);
        await _waitFor(() => engine.urls.isNotEmpty);
        engine.position = const Duration(seconds: 1);
        await _waitFor(() => app.position == const Duration(seconds: 1));
        expect(engine.urls.single, contains('/alpha/'));
        final stops = engine.stops;
        await app.selectMusicConnection('alpha:fixture.multiple');
        await app.selectMusicConnection('local:local');
        expect(app.current!.id, alphaTrack.id);
        expect(app.queue, hasLength(3));
        expect(engine.stops, stops);
        expect(engine.urls, hasLength(1));
        await app.toggleLikeCurrent();
        expect(app.currentLiked, isTrue);
        final alphaState =
            await alpha.runtime.invoke('testState', {'platform': 'alpha'})
                as Map;
        final betaState =
            await beta.runtime.invoke('testState', {'platform': 'beta'}) as Map;
        expect(alphaState['starred'], isTrue);
        expect(alphaState['reports'], greaterThan(0));
        expect(betaState['starred'], isFalse);
        app.next();
        await _waitFor(() => engine.urls.length == 2);
        expect(engine.urls.last, contains('/beta/'));
        app.next();
        await _waitFor(() => engine.urls.length == 3);
        expect(engine.urls.last, file.uri.toString());
        app.pause();
        await app.signOut(connectionKey: 'alpha:fixture.multiple');
        expect(app.queue.map((track) => track.id), [betaTrack.id, local.id]);
        expect(app.current!.id, local.id);
        expect(app.musicAccounts.keys, ['beta:fixture.multiple']);
      } finally {
        app.pause();
        // Join the last play's cache-history write before deleting its Windows directory.
        final current = app.current;
        if (current != null) await app.playbackCache.recordPlayed(current);
        await app.listeningStatistics.flush();
        await app.catalog.cache.settle();
        app.dispose();
        app.localLibrary.dispose();
      }
    },
  );

  testWidgets(
    'the login platform picker can select local without signing out',
    (tester) async {
      final plugins = manager();
      final app = state(plugins);
      addTearDown(app.dispose);
      await tester.runAsync(() async {
        await plugins.importZip(_package());
        await app.bootstrap();
        await app.signInWithCookie('fixture');
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppLoginDialog(context, app),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地音乐').last);
      await tester.pumpAndSettle();
      expect(app.activeConnectionKey, 'local:local');
      expect(app.signedIn, isTrue);
      expect(app.musicAccounts.keys, ['alpha:fixture.multiple']);
      expect(find.text('本地音乐无需登录，其他平台的账号会继续保留。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'QR uses opaque plugin URL and waits for a delayed account after 803',
    () async {
      final plugins = manager();
      await plugins.importZip(_package());
      final app = state(plugins);
      try {
        await app.bootstrap();
        await app.selectMusicConnection('beta:fixture.multiple');
        final url = await app.beginQrLogin();
        expect(url, 'https://radio.test/connect?token=opaque-token');
        expect(await app.pollQrLogin(url!), 802);
        expect(app.isGuest, isTrue);
        expect(await app.pollQrLogin(url), 803);
        expect(app.user.name, 'beta listener');
      } finally {
        app.dispose();
      }
    },
  );

  test(
    'disabling and uninstalling detach all Lua platforms and permit reimport',
    () async {
      final plugins = manager();
      final app = state(plugins);
      try {
        await app.bootstrap();
        await plugins.importZip(_package());
        await plugins.setEnabled('fixture.multiple', false);
        expect(app.availableMusicPlatforms.map((g) => g.provider.id), [
          'local',
        ]);
        expect(app.musicProvider.id, 'local');
        await plugins.setEnabled('fixture.multiple', true);
        expect(app.availableMusicPlatforms.length, 3);
        await plugins.importZip(_package(version: '1.0.1'));
        expect(plugins.plugins.single.error, isNull);
        expect(app.availableMusicPlatforms.length, 3);
        await plugins.uninstall('fixture.multiple');
        expect(app.availableMusicPlatforms.map((g) => g.provider.id), [
          'local',
        ]);
      } finally {
        app.dispose();
      }
    },
  );

  testWidgets(
    'ZIP import from retained settings with HiFi and selection stays build safe',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final plugins = manager();
      final hifi = HifiController(
        const HifiSettings(preferNativeEngine: false),
        engine: null,
        persist: (_) async {},
      );
      final app = AppState(
        pluginManager: plugins,
        catalog:_isolatedCatalog(),
        hifi: hifi,
        hifiSettings: hifi.settings,
        artworkSeedLoader: (_) async => null,
      );
      addTearDown(app.dispose);
      addTearDown(hifi.dispose);
      final packageFile = File('${directory.path}/test-plugin.zip');
      await tester.runAsync(() async {
        await packageFile.writeAsBytes(_package());
        await app.bootstrap();
      });
      const picker = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
        call,
      ) async {
        expect(call.method, 'openFile');
        return [packageFile.path];
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: SelectionArea(
              child: AnimatedBuilder(
                animation: app,
                builder: (_, _) => AppSettingsPage(state: app),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final retainedHifi = tester.element(find.byType(HifiSettingsSection));
      final open = find.byKey(const ValueKey('open-plugin-manager'));
      await tester.scrollUntilVisible(
        open,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final imported = Completer<void>();
      plugins.addListener(() {
        if (!plugins.busy &&
            plugins.plugins.isNotEmpty &&
            !imported.isCompleted) {
          imported.complete();
        }
      });
      await tester.tap(find.text('导入 ZIP'));
      final deadline = Stopwatch()..start();
      while (!imported.isCompleted && deadline.elapsed.inSeconds < 10) {
        // Native file I/O and widget-zone callbacks both need to make progress.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(imported.isCompleted, isTrue, reason: 'ZIP import must complete');
      await tester.pumpAndSettle();
      expect(find.text('Fixture plugin'), findsOneWidget);
      expect(find.text('插件已安装'), findsOneWidget);
      expect(app.musicProvider.id, 'alpha');
      expect(
        tester.element(find.byType(HifiSettingsSection, skipOffstage: false)),
        same(retainedHifi),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.element(find.byType(HifiSettingsSection)),
        same(retainedHifi),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty install offers plugin management without built-in login modes',
    (tester) async {
      final app = state(manager());
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(brightness: Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAppLoginDialog(context, app),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('插件管理'), findsOneWidget);
      expect(find.text('Navidrome'), findsNothing);
      expect(find.text('网易云音乐'), findsNothing);
      expect(find.text('正在生成二维码…'), findsNothing);
    },
  );

  testWidgets(
    'login chooser uses Lua platform labels and only declared methods',
    (tester) async {
      final plugins = manager();
      final app = state(plugins);
      addTearDown(app.dispose);
      await tester.runAsync(() async {
        await plugins.importZip(_package());
        await app.bootstrap();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(brightness: Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAppLoginDialog(context, app),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final chooser = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(chooser.items!.map((entry) => (entry.child as Text).data), [
        '本地音乐',
        'Alpha Music',
        'Beta Radio',
      ]);
      expect(find.text('扫码登录'), findsNothing);
      expect(find.text('短信验证码登录'), findsNothing);
      expect(find.text('密码登录'), findsNothing);
      expect(find.text('网易云音乐'), findsNothing);
      expect(find.text('Navidrome'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    },
  );
}
