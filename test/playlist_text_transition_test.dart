import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/playlist_page.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';

const _playlist = Playlist(
  id: 'text-motion',
  name: 'Rainy day selection',
  trackIds: [],
  trackCount: 12,
  coverSeed: 1,
);

class _Harness extends StatefulWidget {
  const _Harness({this.compact = false, this.reduced = false});
  final bool compact, reduced;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool open = false;
  final scroll = ScrollController();

  void back() {
    returnCoverTransition('playlist:text-motion');
    setState(() => open = false);
  }

  @override
  void dispose() {
    cancelCoverTransitions();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildAppleTheme(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reduced),
      child: Scaffold(
        body: RetainedContentSwitcher(
          currentKey: open ? 'detail' : 'cards',
          retainKeys: open ? const {'cards'} : const {},
          page: open
              ? Padding(
                  padding: EdgeInsets.fromLTRB(
                    widget.compact ? 16 : 240,
                    140,
                    20,
                    0,
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: AppPlaylistHeader(
                      playlist: _playlist,
                      compact: widget.compact,
                      onPlay: null,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  controller: scroll,
                  child: SizedBox(
                    height: 1800,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: AppPlaylistCard(
                          playlist: _playlist,
                          onTap: () => setState(() => open = true),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    ),
  );
}

Finder _label(CoverTextRole role, {bool source = false}) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is CoverTransitionText &&
          widget.role == role &&
          (widget.sourceKey != null) == source,
    );

Finder _flight(CoverTextRole role) =>
    find.byKey(ValueKey('cover-transition-text-${role.name}'));

double _weight(WidgetTester tester) => tester
    .widget<Text>(
      find
          .descendant(
            of: _flight(CoverTextRole.title),
            matching: find.byType(Text),
          )
          .first,
    )
    .style!
    .fontVariations!
    .singleWhere((axis) => axis.axis == 'wght')
    .value;

void main() {
  tearDown(cancelCoverTransitions);

  for (final compact in [false, true]) {
    testWidgets(
      'card text travels to the ${compact ? "phone" : "desktop"} header and back',
      (tester) async {
        tester.view.physicalSize = compact
            ? const Size(390, 844)
            : const Size(1000, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_Harness(compact: compact));
        final origin = {
          for (final role in CoverTextRole.values)
            role: tester.getRect(_label(role, source: true)),
        };
        await tester.tap(find.byType(AppPlaylistCard));
        await tester.pump();
        await tester.pump();
        for (final role in CoverTextRole.values) {
          expect(tester.getRect(_flight(role)), origin[role]);
          expect(
            tester
                .widget<Opacity>(
                  find
                      .descendant(
                        of: _label(role),
                        matching: find.byType(Opacity),
                      )
                      .first,
                )
                .opacity,
            0,
          );
        }
        final restingWeight = _weight(tester);
        await tester.pump(const Duration(milliseconds: 84));
        expect(_weight(tester), lessThan(restingWeight));
        expect(
          tester.getRect(_flight(CoverTextRole.title)),
          isNot(origin[CoverTextRole.title]),
        );
        await tester.pumpAndSettle();
        for (final role in CoverTextRole.values) {
          expect(_flight(role), findsNothing);
        }
        final target = {
          for (final role in CoverTextRole.values)
            role: tester.getRect(_label(role)),
        };
        tester.state<_HarnessState>(find.byType(_Harness)).back();
        await tester.pump();
        await tester.pump();
        for (final role in CoverTextRole.values) {
          expect(tester.getRect(_flight(role)), target[role]);
        }
        await tester.pumpAndSettle();
        for (final role in CoverTextRole.values) {
          expect(_flight(role), findsNothing);
          expect(tester.getRect(_label(role, source: true)), origin[role]);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('rapid back and reopen preserve text position and weight', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 84));
    final before = tester.getRect(_flight(CoverTextRole.title));
    final beforeWeight = _weight(tester);
    tester.state<_HarnessState>(find.byType(_Harness)).back();
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(_flight(CoverTextRole.title)), before);
    expect(_weight(tester), closeTo(beforeWeight, .001));
    await tester.pump(const Duration(milliseconds: 80));
    final returning = tester.getRect(_flight(CoverTextRole.title));
    final returningWeight = _weight(tester);
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(_flight(CoverTextRole.title)), returning);
    expect(_weight(tester), closeTo(returningWeight, .001));
    await tester.pumpAndSettle();
    expect(_flight(CoverTextRole.title), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back before the first overlay paint keeps text at its card', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    final before = tester.getRect(_label(CoverTextRole.title, source: true));
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pump();
    tester.state<_HarnessState>(find.byType(_Harness)).back();
    await tester.pump();
    await tester.pump();
    final flying = _flight(CoverTextRole.title).evaluate().isNotEmpty;
    final visible = flying
        ? _flight(CoverTextRole.title)
        : _label(CoverTextRole.title, source: true);
    expect(tester.getRect(visible), before);
    if (!flying) {
      expect(
        tester
            .widget<Opacity>(
              find
                  .descendant(of: visible, matching: find.byType(Opacity))
                  .first,
            )
            .opacity,
        1,
      );
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scrolling after back returns both labels to their card immediately',
    (tester) async {
      await tester.pumpWidget(const _Harness());
      await tester.tap(find.byType(AppPlaylistCard));
      await tester.pumpAndSettle();
      tester.state<_HarnessState>(find.byType(_Harness)).back();
      await tester.pump();
      await tester.pump();
      expect(_flight(CoverTextRole.title), findsOneWidget);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -70),
      );
      await tester.pump();
      for (final role in CoverTextRole.values) {
        expect(_flight(role), findsNothing);
        expect(
          tester
              .widget<Opacity>(
                find
                    .descendant(
                      of: _label(role, source: true),
                      matching: find.byType(Opacity),
                    )
                    .first,
              )
              .opacity,
          1,
        );
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion keeps card and header text visible', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(reduced: true));
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pumpAndSettle();
    for (final role in CoverTextRole.values) {
      expect(_flight(role), findsNothing);
      expect(
        tester
            .widget<Opacity>(
              find
                  .descendant(of: _label(role), matching: find.byType(Opacity))
                  .first,
            )
            .opacity,
        1,
      );
    }
    tester.state<_HarnessState>(find.byType(_Harness)).back();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
