import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/home_pages.dart';
import 'package:lazer_nextgen/ui/widgets.dart';

List<Track> _tracks(int count) => List.generate(
  count,
  (index) => Track(
    id: '$index',
    title: 'Track $index',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    coverSeed: index,
  ),
);

Widget _host(Widget child, {double width = 960}) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  testWidgets('recent history only reserves occupied rows', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final sample in {1: 72.0, 3: 72.0, 4: 154.0, 9: 236.0}.entries) {
      await tester.pumpWidget(
        _host(
          HomeRecentTrackShelf(tracks: _tracks(sample.key), onPlay: (_, _) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('recent-tracks'))).height,
        sample.value,
        reason: '${sample.key} tracks should not reserve empty rows',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('recent reading order and menu do not change playback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? played;
    String? menu;
    await tester.pumpWidget(
      _host(
        HomeRecentTrackShelf(
          tracks: _tracks(9),
          onPlay: (_, index) => played = index,
          onMenuRequested: (track, _) => menu = track.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('recent-track:0'));
    final second = find.byKey(const ValueKey('recent-track:1'));
    final fourth = find.byKey(const ValueKey('recent-track:3'));
    expect(tester.getTopLeft(second).dy, tester.getTopLeft(first).dy);
    expect(
      tester.getTopLeft(second).dx,
      greaterThan(tester.getTopLeft(first).dx),
    );
    expect(tester.getTopLeft(fourth).dx, tester.getTopLeft(first).dx);
    expect(
      tester.getTopLeft(fourth).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    await tester.tap(find.text('Track 6'));
    expect(played, 6);
    await tester.tap(
      find.descendant(
        of: second,
        matching: find.byIcon(Icons.more_horiz_rounded),
      ),
    );
    expect(menu, '1');
    expect(played, 6);
  });

  testWidgets('recent paging starts on a complete next page', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? played;
    await tester.pumpWidget(
      _host(
        HomeRecentTrackShelf(
          tracks: _tracks(12),
          onPlay: (_, index) => played = index,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialLeft = tester
        .getTopLeft(find.byKey(const ValueKey('recent-track:0')))
        .dx;
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    final next = find.byKey(const ValueKey('recent-track:9'));
    expect(tester.getTopLeft(next).dx, closeTo(initialLeft, .1));
    await tester.tap(find.text('Track 10'));
    expect(played, 10);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all four desktop shortcuts fit the row and support keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var daily = 0;
    await tester.pumpWidget(
      _host(
        HomeActionShelf(
          busy: false,
          covers: const [],
          onDaily: () => daily++,
          onFm: () {},
          onHeart: () {},
          onReplay: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cards = find.byType(FilledCoverCard);
    expect(cards, findsNWidgets(4));
    expect(tester.getBottomRight(cards.last).dx, closeTo(960, .1));
    expect(tester.getSize(cards.first).width, tester.getSize(cards.last).width);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(daily, 1);
  });

  testWidgets('phone history stays readable and shortcuts remain swipeable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        HomeRecentTrackShelf(tracks: _tracks(4), onPlay: (_, _) {}),
        width: 350,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('recent-tracks'))).height,
      214,
    );
    expect(tester.getSize(find.byType(AppArtistTrackCard).first).width, 350);
    await tester.pumpWidget(
      _host(
        HomeActionShelf(
          busy: false,
          covers: const [],
          onDaily: () {},
          onFm: () {},
          onHeart: () {},
          onReplay: () {},
        ),
        width: 350,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FilledCoverCard).first).width, 228);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover collage does not keep scheduling idle animation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _host(
          HomeActionShelf(
            busy: false,
            covers: [
              Uri.file('${Directory.current.path}/assets/zako.png').toString(),
            ],
            onDaily: () {},
            onFm: () {},
            onHeart: () {},
            onReplay: () {},
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
