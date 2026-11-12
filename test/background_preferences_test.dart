import 'support/music_gateway.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/diagnostics/app_log.dart';

class _Catalog extends Catalog {
  _Catalog({super.gateway});

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

class _ArtworkGateway extends TestMusicGateway {
  final details = Completer<MusicSong>();
  @override
  Future<MusicSong> song(MusicId id) => details.future;
  @override
  MusicUser get user =>
      MusicUser(id: id(MusicEntityKind.user, '7'), name: 'Tester');
}

Track _track(String id) => Track(
  id: 'fixture:test:song:$id',
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
  coverUrl: 'https://cover.test/$id',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('custom background crop and blur settings persist', () async {
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setBackgroundImageTransform(
      player: false,
      alignmentX: 2,
      alignmentY: -.5,
      scale: 4,
    );
    await state.setBackgroundBlur(18, player: false);
    expect(state.backgroundImageAlignmentX, 1);
    expect(state.backgroundImageAlignmentY, -.5);
    expect(state.backgroundImageScale, 3);
    expect(state.backgroundBlur, 18);

    final restored = AppState(catalog: _Catalog());
    addTearDown(restored.dispose);
    await restored.bootstrap();
    expect(restored.backgroundImageAlignmentX, 1);
    expect(restored.backgroundImageAlignmentY, -.5);
    expect(restored.backgroundImageScale, 3);
    expect(restored.backgroundBlur, 18);
  });

  test(
    'background modes, frame rates and colors restore independently',
    () async {
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      expect(state.browseBackgroundFps, 30);
      expect(state.playerBackgroundFps, 0);
      await state.setAppBackground(AppBackgroundMode.solidColor);
      await state.setPlayerBackground(AppBackgroundMode.nowPlayingStatic);
      await state.setBackgroundFps(20);
      await state.setBackgroundFps(10, player: true);
      await state.setBackgroundColor(Colors.blue);
      await state.setBackgroundColor(Colors.green, player: true);
      await Future.wait([
        state.setPlaylistOrder(['c', 'a', 'b']),
        state.setPlaylistOrder(['b', 'a', 'c', 'b']),
      ]);
      final restored = AppState(catalog: _Catalog());
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.backgroundMode, AppBackgroundMode.solidColor);
      expect(restored.playerBackground, AppBackgroundMode.nowPlayingStatic);
      expect(restored.browseBackgroundFps, 20);
      expect(restored.playerBackgroundFps, 10);
      expect(
        restored.browseBackgroundColor!.toARGB32(),
        Colors.blue.toARGB32(),
      );
      expect(
        restored.playerBackgroundColor!.toARGB32(),
        Colors.green.toARGB32(),
      );
      expect(restored.playlistOrder, ['b', 'a', 'c']);
    },
  );

  test(
    'track changes refresh artwork color without a mounted page and reject stale results',
    () async {
      final a = Completer<Color?>(), b = Completer<Color?>();
      final state = AppState(
        catalog: _Catalog(),
        artworkSeedLoader: (url) => url!.endsWith('/a') ? a.future : b.future,
      );
      addTearDown(state.dispose);
      state.paletteMode = AppPaletteMode.nowPlaying;
      state.playQueue([_track('a')]);
      await Future<void>.delayed(Duration.zero);
      state.playQueue([_track('b')]);
      await Future<void>.delayed(Duration.zero);
      b.complete(Colors.blue);
      await Future<void>.delayed(Duration.zero);
      expect(state.accentSeed, Colors.blue);
      a.complete(Colors.red);
      await Future<void>.delayed(Duration.zero);
      expect(state.accentSeed, Colors.blue);
    },
  );

  test('paused next and previous refresh the artwork accent', () async {
    final requested = <String?>[];
    final state = AppState(
      catalog: _Catalog(),
      artworkSeedLoader: (url) async {
        requested.add(url);
        return url!.endsWith('/a') ? Colors.red : Colors.blue;
      },
    );
    addTearDown(state.dispose);
    state.paletteMode = AppPaletteMode.nowPlaying;
    state.playQueue([_track('a'), _track('b')]);
    await Future<void>.delayed(Duration.zero);
    state.pause();
    expect(state.accentSeed, Colors.red);

    state.next();
    await Future<void>.delayed(Duration.zero);
    expect(state.playing, isFalse);
    expect(state.accentSeed, Colors.blue);

    state.previous();
    await Future<void>.delayed(Duration.zero);
    expect(state.playing, isFalse);
    expect(state.accentSeed, Colors.red);
    expect(requested, [
      'https://cover.test/a',
      'https://cover.test/b',
      'https://cover.test/a',
    ]);
  });

  test('a slow palette cannot overwrite a newer paused selection', () async {
    final old = Completer<Color?>();
    final requested = <String?>[];
    final state = AppState(
      catalog: _Catalog(),
      artworkSeedLoader: (url) {
        requested.add(url);
        if (url!.endsWith('/b')) return old.future;
        return Future.value(url.endsWith('/a') ? Colors.red : Colors.blue);
      },
    );
    addTearDown(state.dispose);
    state.paletteMode = AppPaletteMode.nowPlaying;
    state.playQueue([_track('a'), _track('b'), _track('c')]);
    await Future<void>.delayed(Duration.zero);
    state.pause();
    state.next();
    state.next();
    await Future<void>.delayed(Duration.zero);
    expect(state.current?.id, 'fixture:test:song:c');
    expect(state.accentSeed, Colors.blue);
    old.complete(Colors.green);
    await Future<void>.delayed(Duration.zero);
    expect(state.accentSeed, Colors.blue);
    expect(requested, [
      'https://cover.test/a',
      'https://cover.test/b',
      'https://cover.test/c',
    ]);
  });

  test('paused track hydration refreshes the changed artwork URL', () async {
    final gateway = _ArtworkGateway();
    final requested = <String?>[];
    final state = AppState(
      catalog: _Catalog(gateway: gateway),
      artworkSeedLoader: (url) async {
        requested.add(url);
        return url!.endsWith('/hydrated') ? Colors.green : Colors.red;
      },
    );
    addTearDown(state.dispose);
    state.paletteMode = AppPaletteMode.nowPlaying;
    state.playQueue([_track('1'), _track('2')]);
    await Future<void>.delayed(Duration.zero);
    state.pause();
    state.next();
    await Future<void>.delayed(Duration.zero);
    gateway.details.complete(
      MusicSong(
        id: gateway.id(MusicEntityKind.song, '2'),
        title: '2',
        artists: [],
        albumName: 'Album',
        duration: Duration(minutes: 3),
        coverUrl: 'https://cover.test/hydrated',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(state.playing, isFalse);
    expect(state.current?.coverUrl, 'https://cover.test/hydrated');
    expect(state.accentSeed, Colors.green);
    expect(requested, [
      'https://cover.test/1',
      'https://cover.test/2',
      'https://cover.test/hydrated',
    ]);
  });

  for (final rate in [30.0, 10.0, null]) {
    testWidgets('background cadence is independent of mesh quality at $rate', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumFlowBackground(
            colors: albumFlowColors(Colors.blue),
            frameRate: rate,
            quality: .1,
          ),
        ),
      );
      await tester.pump();
      final painter = tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byType(AlbumFlowBackground),
                  matching: find.byType(CustomPaint),
                )
                .first,
          )
          .painter!;
      int updates = 0;
      painter.addListener(() => updates++);
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      final expected = rate ?? 60;
      expect(
        updates,
        inInclusiveRange(expected.toInt() - 2, expected.toInt() + 2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'automatic cadence follows a 360 Hz display without a 240 fps ceiling',
    (tester) async {
      tester.view.display.refreshRate = 360;
      addTearDown(tester.view.display.resetRefreshRate);
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumFlowBackground(
            colors: albumFlowColors(Colors.blue),
            frameRate: null,
            quality: .1,
          ),
        ),
      );
      await tester.pump();
      final painter = tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byType(AlbumFlowBackground),
                  matching: find.byType(CustomPaint),
                )
                .first,
          )
          .painter!;
      int updates = 0;
      painter.addListener(() => updates++);
      for (int i = 0; i < 360; i++) {
        await tester.pump(const Duration(microseconds: 2778));
      }
      expect(updates, inInclusiveRange(358, 360));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'static background draws the mesh once and leaves no animation running',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumBlurFlowCanvas(
            track: null,
            mode: AppBackgroundMode.nowPlayingStatic,
            uiAlpha: .7,
          ),
        ),
      );
      await tester.pump();
      final flow = tester.widget<AlbumFlowBackground>(
        find.byType(AlbumFlowBackground),
      );
      expect(flow.animated, isFalse);
      expect(flow.solid, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  test('exported log buffer stays bounded and redacts credentials', () {
    final log = AppLog(maximumLines: 2, maximumCharacters: 1024);
    log.record('first');
    log.record('Cookie: MUSIC_U=secret');
    log.record('https://music.test/song?token=secret');
    final text = log.snapshot();
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('first')));
    expect(text, contains('redacted'));
    expect(text.split('\n'), hasLength(2));
  });
}
