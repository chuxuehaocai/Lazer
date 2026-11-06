// Opt-in app integration check. Supply paths, never credentials, with
// --dart-define=LAZER_TEST_PLUGIN_ZIP=... --dart-define=LAZER_TEST_COOKIE_FILE=...
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const zipPath = String.fromEnvironment('LAZER_TEST_PLUGIN_ZIP');
  const cookiePath = String.fromEnvironment('LAZER_TEST_COOKIE_FILE');
  test(
    'live Lua plugin imports, logs in, populates the app and restores after restart',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'lazer-live-app-',
      );
      // This opt-in Flutter test lives under tool/ to stay out of offline CI.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temporary.path,
          );
      final states = <AppState>[];
      AppState create() {
        final state = AppState(
          pluginManager: PluginManager(
            rootDirectory: Directory('${temporary.path}/plugins'),
          ),
          artworkSeedLoader: (_) async => null,
        );
        states.add(state);
        return state;
      }

      try {
        final app = create();
        await app.bootstrap();
        expect(app.musicProvider.id, 'local');
        final installed = await app.pluginManager.importZip(
          await File(zipPath).readAsBytes(),
        );
        expect(installed.error, isNull);
        expect(app.isLuaProvider, isTrue);
        expect(app.musicProvider.name, '网易云音乐');
        expect(app.musicAuthenticationMethods, containsAll(['qr', 'cookie']));
        final login = await app.signInWithCookie(
          await File(cookiePath).readAsString(),
        );
        expect(
          login.ok,
          isTrue,
          reason: 'The opt-in development account should log in through Lua',
        );
        final originalAccount = app.user.handle;
        try {
          await app.catalog.userCollections(app.user.userId);
        } catch (error) {
          fail('Live collection mapping failed (${error.runtimeType})');
        }
        await app.refreshHome(force: true);
        await app.refreshCollections(force: true);
        expect(app.isGuest, isFalse);
        expect(app.homeError, isNull);
        expect(app.home?.isEmpty, isFalse);
        expect(app.collectionsError, isNull);
        final liked = app.collections.liked!;
        expect(
          MusicId.tryParse(liked.id)!.value != '__lazer_favorites__',
          isTrue,
        );
        expect(
          app.collections.created.any((list) => list.id == liked.id),
          isFalse,
        );
        expect(
          app.collections.subscribed.any((list) => list.id == liked.id),
          isFalse,
        );
        final playlists =
            [
                liked,
                ...app.collections.created,
                ...app.collections.subscribed,
              ].where((list) => list.trackCount > 0).toList()
              ..sort((a, b) => a.trackCount.compareTo(b.trackCount));
        if (playlists.isNotEmpty) {
          final selected = playlists.first;
          final loaded = await app.catalog.playlistTracks(selected.id);
          final cold = Catalog(cache: app.catalog.cache)
            ..connections.add(app.catalog.activeGateway, select: true);
          final stored = await cold.cachedPlaylistTracks(selected.id);
          expect(
            stored?.length == loaded.length,
            isTrue,
            reason:
                'A newly constructed catalogue must restore the complete playlist snapshot',
          );
          expect(
            (await cold.cachedUserCollections(app.user.userId))?.liked?.id ==
                liked.id,
            isTrue,
          );
        }
        final search = await app.search('周杰伦');
        expect(search.tracks.isNotEmpty, isTrue);
        final stream = await app.catalog.audioSourceFor(
          search.tracks.first,
          useCache: false,
        );
        expect(stream != null, isTrue);
        final qr = await app.beginQrLogin();
        expect(qr != null, isTrue);
        expect({801, 802, 800}.contains(await app.pollQrLogin(qr!)), isTrue);
        expect(
          app.user.handle == originalAccount,
          isTrue,
          reason: 'Refreshing QR must preserve the current account',
        );
        await app.selectMusicConnection('local:local');
        expect(app.isGuest, isFalse);
        expect(app.activeMusicSignedIn, isFalse);
        expect(app.user.handle == originalAccount, isTrue);
        await app.selectMusicConnection('netease:lazer.netease');
        expect(app.user.handle == originalAccount, isTrue);
        app.dispose();
        states.remove(app);

        final restored = create();
        await restored.bootstrap();
        expect(restored.activeConnectionKey, 'netease:lazer.netease');
        expect(
          restored.user.handle == originalAccount,
          isTrue,
          reason: 'Startup must adopt the persisted Lua session',
        );
        expect(restored.isGuest, isFalse);
        expect(restored.homeError, isNull);
        await restored.signOut();
        restored.dispose();
        states.remove(restored);
        final signedOut = create();
        await signedOut.bootstrap();
        expect(signedOut.isGuest, isTrue);
      } finally {
        for (final state in states) {
          state.dispose();
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await temporary.delete(recursive: true);
      }
    },
    skip: zipPath.isEmpty || cookiePath.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
