import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

Widget _host(Widget child, {double textScale = 1, bool compactTheme = false}) =>
    MaterialApp(
      theme: buildAppleTheme(compact: compactTheme),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

void main() {
  testWidgets('paging arrows name the action and hide unavailable semantics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(HomeRecentTrackShelf(tracks: _tracks(12), onPlay: (_, _) {})),
    );
    await tester.pumpAndSettle();
    Set<String> attachedLabels() {
      final labels = <String>{};
      void visit(SemanticsNode node) {
        labels.add(node.getSemanticsData().label);
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(Scaffold)));
      return labels;
    }

    expect(attachedLabels(), isNot(contains('Previous page')));
    expect(attachedLabels(), contains('Next page'));
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(attachedLabels(), contains('Previous page'));
    expect(attachedLabels(), isNot(contains('Next page')));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('forced phone theme reaches shared cards in a wide window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final compact in [true, false, true]) {
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              AppArtistTrackCard(
                track: _tracks(1).first,
                current: false,
                onTap: () {},
              ),
              AppTrackRow(track: _tracks(1).first, index: 0, onTap: () {}),
              HomeActionShelf(
                busy: false,
                covers: const [],
                onDaily: () {},
                onFm: () {},
              ),
              ChartShelf(
                charts: const [
                  MusicChart(
                    id: 'chart',
                    title: 'Chart',
                    source: 'test',
                    issueLabel: 'Today',
                    entries: [],
                  ),
                ],
                onOpen: (_) {},
              ),
            ],
          ),
          compactTheme: compact,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(AppArtistTrackCard)).height,
        compact ? 66 : 72,
      );
      expect(find.text('Album'), compact ? findsNothing : findsOneWidget);
      expect(
        tester.getSize(find.byType(FilledCoverCard).first).width,
        compact ? 228 : 617,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('charts'))).height,
        compact ? 274 : 294,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('phone recent rows retain density and swipe to playable tracks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? played;
    String? menu;
    await tester.pumpWidget(
      _host(
        HomeRecentTrackShelf(
          tracks: _tracks(6),
          onPlay: (_, index) => played = index,
          onMenuRequested: (track, _) => menu = track.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('recent-track:0'));
    final second = find.byKey(const ValueKey('recent-track:1'));
    expect(tester.getSize(first).height, 66);
    expect(tester.getTopLeft(second).dx, tester.getTopLeft(first).dx);
    expect(tester.getTopLeft(second).dy - tester.getTopLeft(first).dy, 74);

    await tester.tap(find.text('Track 1'));
    expect(played, 1);
    await tester.tap(find.byKey(const ValueKey('recent-track-menu-1')));
    expect(menu, '1');
    expect(played, 1, reason: 'Opening the menu must preserve playback');

    await tester.drag(
      find.byKey(const ValueKey('recent-tracks')),
      const Offset(-380, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track 4'));
    expect(played, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide phone layout retains three-row column ordering', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        HomeRecentTrackShelf(
          compact: true,
          tracks: _tracks(6),
          onPlay: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('recent-track:0'));
    final second = find.byKey(const ValueKey('recent-track:1'));
    final fourth = find.byKey(const ValueKey('recent-track:3'));
    expect(tester.getTopLeft(second).dx, tester.getTopLeft(first).dx);
    expect(tester.getTopLeft(fourth).dy, tester.getTopLeft(first).dy);
    expect(
      tester.getTopLeft(fourth).dx,
      greaterThan(tester.getTopLeft(first).dx),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('restored phone cards still expand for accessible text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        HomeRecentTrackShelf(
          tracks: _tracks(3),
          onPlay: (_, _) {},
          onMenuRequested: (_, _) {},
        ),
        textScale: 2.4,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(AppArtistTrackCard).first).height,
      greaterThan(66),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      _host(
        HomeActionShelf(
          busy: false,
          covers: const [],
          onDaily: () {},
          onFm: () {},
        ),
        textScale: 2.4,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
