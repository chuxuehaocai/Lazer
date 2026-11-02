import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/player/player_backdrop.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/widgets/player_seek_bar.dart';

class _PlayerState extends AppState {
  _PlayerState({required bool largeText}) {
    uiMode = AppUiMode.mobile;
    lyricControlsSeconds = 2;
    lyrics = parseLrc(
      '[00:00.00]First lyric line\n[00:04.00]Second lyric line\n'
      '[00:08.00]Third lyric line',
    );
    if (largeText) {
      fontPreferences = const FontPreferences({
        FontCategory.playerTitle: FontCustomization(scale: 1.6),
        FontCategory.playerArtist: FontCustomization(scale: 1.6),
      });
    }
  }

  @override
  Track? get current => const Track(
    id: 'mobile-layout',
    title: 'A long song title with enough words to fill a narrow screen',
    artist: 'An artist name that should never crowd the playback controls',
    album: 'Album',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  );

  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('cover shadow extends evenly into the side gutters at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final oldDisableShadows = debugDisableShadows;
      debugDisableShadows = false;
      final state = _PlayerState(largeText: false)
        ..playerBackground = AppBackgroundMode.solidColor
        ..playerBackgroundColor = Colors.white;
      addTearDown(state.dispose);
      const captureKey = ValueKey('mobile-cover-shadow-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            theme: buildAppleTheme(),
            home: NowPlayingPage(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final art = tester.getRect(
        find.byKey(const ValueKey('now-playing-cover')),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final backdrop = tester.renderObject<RenderRepaintBoundary>(
        find
            .descendant(
              of: find.byType(AlbumBlurFlow),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      try {
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final pixels = (await image.toByteData())!.buffer.asUint8List();
          final background = await backdrop.toImage();
          final baseline = (await background.toByteData())!.buffer
              .asUint8List();
          // Normalize against the player's gradients to compare shadow strength.
          double transmissionAt(Offset point) {
            final index =
                (point.dy.floor() * image.width + point.dx.floor()) * 4;
            return pixels[index] / baseline[index];
          }

          final left = transmissionAt(Offset(art.left - 6, art.center.dy));
          final right = transmissionAt(Offset(art.right + 5, art.center.dy));
          final top = transmissionAt(Offset(art.center.dx, art.top - 6));
          final bottom = transmissionAt(Offset(art.center.dx, art.bottom + 5));
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          background.dispose();
          final orientation = size.width > size.height
              ? 'landscape'
              : 'portrait';
          final capture = File('diag/player/cover-shadow-$orientation.png');
          await capture.parent.create(recursive: true);
          await capture.writeAsBytes(png!.buffer.asUint8List());
          expect(
            left,
            lessThan(.96),
            reason: 'left shadow must survive clipping',
          );
          expect(
            right,
            lessThan(.96),
            reason: 'right shadow must survive clipping',
          );
          expect((left - right).abs(), lessThan(.02));
          expect((top - bottom).abs(), lessThan(.02));
        });
      } finally {
        debugDisableShadows = oldDisableShadows;
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(700, 1024),
    const Size(568, 320),
    const Size(844, 390),
  ]) {
    for (final largeText in [false, true]) {
      testWidgets('player fits $size with large text $largeText', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _PlayerState(largeText: largeText);
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 24, bottom: 20),
                textScaler: TextScaler.linear(largeText ? 1.3 : 1),
              ),
              child: child!,
            ),
            home: NowPlayingPage(state: state),
          ),
        );
        await tester.pump();

        final art = find.byKey(const ValueKey('now-playing-cover'));
        final details = find.byKey(const ValueKey('artwork-track-details'));
        final transport = find.byKey(const ValueKey('now-playing-transport'));
        final large = tester.getRect(art);
        final artElement = tester.element(art);
        final landscape = size.width > size.height;
        expect(large.shortestSide, greaterThan(landscape ? 80 : 100));
        if (landscape) {
          final info = tester.getRect(details);
          final controls = tester.getRect(transport);
          expect(large.right, lessThan(controls.left));
          if (info.left < controls.left) {
            expect(large.bottom, lessThan(info.top));
            expect(info.right, lessThan(controls.left));
          } else {
            expect(large.right, lessThan(info.left));
            expect(info.left, closeTo(controls.left, .01));
          }
        } else {
          expect(large.bottom, lessThan(tester.getRect(details).top));
        }
        final detailViewport = find
            .ancestor(of: details, matching: find.byType(SingleChildScrollView))
            .first;
        final detailScroll = tester.state<ScrollableState>(
          find.descendant(
            of: detailViewport,
            matching: find.byType(Scrollable),
          ),
        );
        expect(detailScroll.position.maxScrollExtent, 0);
        expect(tester.takeException(), isNull);

        await tester.tap(art);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.element(art), same(artElement));
        final small = tester.getRect(art);
        final compactDetails = tester.getRect(details);
        expect(small.width, closeTo(64, 1));
        expect(small.right, lessThan(compactDetails.left));
        expect(small.center.dy, closeTo(compactDetails.center.dy, .01));
        final lyricPane = tester.getRect(
          find
              .descendant(
                of: find.byType(ArtworkLyricsLayout),
                matching: find.byType(LayoutId),
              )
              .first,
        );
        expect(lyricPane.height, greaterThan(50));
        expect(lyricPane.bottom, lessThanOrEqualTo(small.top));
        final rail = tester.getRect(find.byType(PlayerSeekBar));
        final play = tester.getRect(
          find.byKey(const ValueKey('now-playing-play')),
        );
        expect(rail.right, lessThanOrEqualTo(size.width - 20));
        expect(play.bottom, lessThanOrEqualTo(size.height - 20));
        expect(tester.takeException(), isNull);

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        final summary = tester.getRect(
          find.byKey(const ValueKey('compact-player-summary')),
        );
        expect(summary.top, greaterThanOrEqualTo(24 + 18));
        expect(summary.bottom, lessThan(size.height - 20));
        expect(
          tester
              .widget<FadeTransition>(
                find.byKey(const ValueKey('compact-player-summary-fade')),
              )
              .opacity
              .value,
          1,
        );
        await tester.tap(find.byKey(const ValueKey('compact-player-summary')));
        await tester.pump();
        await tester.pumpAndSettle();
        await tester.tap(art);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.getRect(art), large);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
