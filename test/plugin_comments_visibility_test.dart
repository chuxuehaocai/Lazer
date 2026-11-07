import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'player comments follow the playing songs enabled Lua capability',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson({
          'id': 'test.comments',
          'provider': 'netease',
          'name': 'Test',
          'version': '1.0.0',
          'apiVersion': 1,
        }),
        sources: const {'main.lua': 'return {call=function() return {} end}'},
        dataDirectory: 'unused-comment-runtime',
      );
      final provider = LuaMusicGateway(
        runtime: runtime,
        provider: MusicProvider.netease,
        connectionId: 'test.comments',
        declaredCapabilities: {MusicCapability.comments},
      );
      final state = AppState(catalog: Catalog());
      addTearDown(state.dispose);
      const track = Track(
        id: '7',
        title: 'Fixture',
        artist: 'Artist',
        album: 'Album',
        duration: Duration(minutes: 2),
        coverSeed: 1,
      );
      state.playQueue([track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: DesktopNowPlaying(
              state: state,
              track: track,
              artwork: const SizedBox(),
              lyrics: const Text('Lyrics'),
              comments: const Text('Comments'),
              queue: const SizedBox(),
              pane: DesktopNowPlayingPane.lyrics,
              onPaneChanged: (_) {},
              onBack: () {},
              onSaveArtwork: () {},
              onFullscreen: () {},
              controlsVisible: true,
              onActivity: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('desktop-comments')), findsNothing);
      state.catalog.connections.add(provider);
      state.notifyListeners();
      await tester.pump();
      expect(find.byKey(const ValueKey('desktop-comments')), findsOneWidget);

      final qualified = Track.fromJson({
        ...track.toJson(),
        'id': provider.id(MusicEntityKind.song, '7').cacheKey,
      });
      expect(state.commentsGatewayFor(qualified), same(provider));
      expect(
        state.commentsGatewayFor(
          qualified.copyWith(localPath: 'download.flac'),
        ),
        same(provider),
      );
      final local = Track.fromJson({
        ...track.toJson(),
        'id': 'local:fixture',
        'localPath': 'fixture.flac',
      });
      expect(state.commentsGatewayFor(local), isNull);
      state.catalog.connections.remove(GatewayRegistry.keyOf(provider));
      state.notifyListeners();
      await tester.pump();
      expect(find.byKey(const ValueKey('desktop-comments')), findsNothing);
      expect(state.commentsGatewayFor(qualified), isNull);
      state.pause();
    },
  );
}
