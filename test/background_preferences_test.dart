import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/diagnostics/app_log.dart';

class _Catalog extends Catalog {
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Track _track(String id) => Track(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
  coverUrl: 'https://cover.test/$id',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'background modes, frame rates and colors restore independently',
    () async {
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      expect(state.browseBackgroundFps, 30);
      expect(state.playerBackgroundFps, 0);
      await state.setLegacyBackground(LegacyBackgroundMode.solidColor);
      await state.setPlayerBackground(LegacyBackgroundMode.nowPlayingStatic);
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
      expect(restored.legacyBackground, LegacyBackgroundMode.solidColor);
      expect(restored.playerBackground, LegacyBackgroundMode.nowPlayingStatic);
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
      state.legacyPalette = LegacyPaletteMode.nowPlaying;
      state.playQueue([_track('a')]);
      await Future<void>.delayed(Duration.zero);
      state.playQueue([_track('b')]);
      await Future<void>.delayed(Duration.zero);
      b.complete(Colors.blue);
      await Future<void>.delayed(Duration.zero);
      expect(state.legacyAccentSeed, Colors.blue);
      a.complete(Colors.red);
      await Future<void>.delayed(Duration.zero);
      expect(state.legacyAccentSeed, Colors.blue);
    },
  );

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
          home: LegacyAlbumBackdrop(
            track: null,
            mode: LegacyBackgroundMode.nowPlayingStatic,
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
