import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/home_pages.dart';
import 'package:lazer_nextgen/ui/playlist_page.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';

class _FlightHarness extends StatefulWidget {
  const _FlightHarness({this.disableAnimations = false});
  final bool disableAnimations;

  @override
  State<_FlightHarness> createState() => _FlightHarnessState();
}

class _FlightHarnessState extends State<_FlightHarness> {
  final GlobalKey source = GlobalKey();
  bool opened = false;
  bool moved = false;

  void moveDestination() => setState(() => moved = true);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.disableAnimations),
      child: Scaffold(
        body: Stack(
          children: <Widget>[
            if (!opened)
              Positioned(
                left: 24,
                top: 32,
                child: GestureDetector(
                  onTap: () {
                    rememberCoverTransition('playlist:flight', source);
                    setState(() => opened = true);
                  },
                  child: SizedBox.square(
                    key: source,
                    dimension: 80,
                    child: const ColoredBox(color: Colors.red),
                  ),
                ),
              ),
            if (opened)
              Positioned(
                left: moved ? 420 : 320,
                top: moved ? 200 : 160,
                child: const CoverTransitionTarget(
                  identity: 'playlist:flight',
                  size: 180,
                  child: ColoredBox(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  for (final daily in <bool>[false, true]) {
    testWidgets(
      '${daily ? 'daily recommendations' : 'playlist card'} records its real source bounds',
      (tester) async {
        final playlist = Playlist(
          id: daily ? dailyRecommendationsPlaylistId : 'card',
          name: 'Collection',
          trackIds: const [],
          coverSeed: 1,
        );
        var opened = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Center(
                  child: SizedBox(
                    width: 550,
                    child: opened
                        ? AppPlaylistHeader(
                            playlist: playlist,
                            compact: false,
                            onPlay: null,
                          )
                        : daily
                        ? HomeActionShelf(
                            busy: false,
                            covers: const [],
                            onDaily: () => setState(() => opened = true),
                          )
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: AppPlaylistCard(
                              playlist: playlist,
                              onTap: () => setState(() => opened = true),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final source = daily
            ? find.byType(FilledCoverCard).first
            : find.descendant(
                of: find.byType(AppPlaylistCard),
                matching: find.byType(AppCover),
              );
        final sourceRect = tester.getRect(source);
        await tester.tap(source);
        await tester.pump();
        await tester.pump();
        final flight = find.byKey(
          const ValueKey<String>('cover-transition-flight'),
        );
        expect(flight, findsOneWidget);
        expect(tester.getRect(flight), sourceRect);
        await tester.pumpAndSettle();
        expect(flight, findsNothing);
        expect(find.byType(AppPlaylistHeader), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('artwork flies from its card bounds and tracks a moving target', (
    tester,
  ) async {
    await tester.pumpWidget(const _FlightHarness());
    final state = tester.state<_FlightHarnessState>(
      find.byType(_FlightHarness),
    );
    final sourceRect = tester.getRect(find.byKey(state.source));
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    await tester.pump();
    final flight = find.byKey(
      const ValueKey<String>('cover-transition-flight'),
    );
    expect(flight, findsOneWidget);
    expect(tester.getRect(flight), sourceRect);
    final destination = find.byType(CoverTransitionTarget);
    final hidden = find.descendant(
      of: destination,
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(hidden).opacity, 0);

    await tester.pump(const Duration(milliseconds: 230));
    final middle = tester.getRect(flight);
    expect(middle.width, greaterThan(sourceRect.width));
    expect(middle.left, greaterThan(sourceRect.left));
    expect(middle.left, lessThan(tester.getRect(destination).left));
    state.moveDestination();
    await tester.pump(const Duration(milliseconds: 160));
    final beforeRetarget = tester.getRect(flight);
    // The target's new layout is available to the overlay on the next frame.
    await tester.pump(const Duration(milliseconds: 1));
    final retargeted = tester.getRect(flight);
    // Destination changes preserve the presented frame; the spring then
    // follows the new layout instead of teleporting with a lerped endpoint.
    expect((retargeted.topLeft - beforeRetarget.topLeft).distance, lessThan(1));
    await tester.pump(const Duration(milliseconds: 240));
    final nearEnd = tester.getRect(flight);
    expect(nearEnd.left, greaterThan(400));
    expect(nearEnd.top, greaterThan(190));
    await tester.pumpAndSettle();
    expect(flight, findsNothing);
    expect(tester.widget<Opacity>(hidden).opacity, 1);
    expect(
      tester.getRect(destination),
      const Rect.fromLTWH(420, 200, 180, 180),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion leaves artwork visible without an overlay', (
    tester,
  ) async {
    await tester.pumpWidget(const _FlightHarness(disableAnimations: true));
    final state = tester.state<_FlightHarnessState>(
      find.byType(_FlightHarness),
    );
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('cover-transition-flight')),
      findsNothing,
    );
    expect(
      tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(CoverTransitionTarget),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a collection during the flight removes the overlay', (
    tester,
  ) async {
    await tester.pumpWidget(const _FlightHarness());
    final state = tester.state<_FlightHarnessState>(
      find.byType(_FlightHarness),
    );
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('cover-transition-flight')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
