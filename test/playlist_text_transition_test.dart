import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  const _Harness({
    this.compact = false,
    this.reduced = false,
    this.textScale = 1,
  });
  final bool compact, reduced;
  final double textScale;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final screen = GlobalKey();
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
    builder: (context, child) => RepaintBoundary(key: screen, child: child),
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: widget.reduced,
        textScaler: TextScaler.linear(widget.textScale),
      ),
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

Finder _label(
  CoverTextRole role, {
  bool source = false,
  bool skipOffstage = true,
}) => find.byWidgetPredicate(
  (widget) =>
      widget is CoverTransitionText &&
      widget.role == role &&
      (widget.sourceKey != null) == source,
  skipOffstage: skipOffstage,
);

Finder _flight(CoverTextRole role) =>
    find.byKey(ValueKey('cover-transition-text-${role.name}'));

void main() {
  tearDown(cancelCoverTransitions);

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets(
      'caption glyphs keep their endpoint layout at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_Harness(compact: true, textScale: scale));
        RenderParagraph paragraph(Finder parent) =>
            tester.renderObject<RenderParagraph>(
              find
                  .descendant(
                    of: parent,
                    matching: find.byType(RichText),
                    skipOffstage: false,
                  )
                  .first,
            );
        Object glyphs(RenderParagraph p) => <Object>[
          p.size,
          p.didExceedMaxLines,
          p
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: 0,
                  extentOffset: p.text.toPlainText().length,
                ),
              )
              .map((box) => (box.left, box.top, box.right, box.bottom))
              .toList(),
        ];
        final source = {
          for (final role in CoverTextRole.values)
            role: glyphs(paragraph(_label(role, source: true))),
        };
        await tester.tap(find.byType(AppPlaylistCard));
        await tester.pump();
        await tester.pump();
        final target = {
          for (final role in CoverTextRole.values)
            role: glyphs(paragraph(_label(role))),
        };
        Future<void> checkFrames() async {
          var frames = 0;
          final retained = {
            for (final role in CoverTextRole.values)
              role: tester
                  .widgetList<RichText>(
                    find.descendant(
                      of: _flight(role),
                      matching: find.byType(RichText),
                    ),
                  )
                  .toList(),
          };
          while (_flight(CoverTextRole.title).evaluate().isNotEmpty &&
              frames < 120) {
            for (final role in CoverTextRole.values) {
              final labels = find.descendant(
                of: _flight(role),
                matching: find.byType(RichText),
              );
              expect(labels, findsNWidgets(2));
              expect(
                tester.widget<RichText>(labels.at(0)),
                same(retained[role]![0]),
              );
              expect(
                tester.widget<RichText>(labels.at(1)),
                same(retained[role]![1]),
              );
              // The existing ellipsis/line breaks must remain stable, including
              // the last visible glyph; only the paragraph transform changes.
              expect(
                glyphs(tester.renderObject<RenderParagraph>(labels.at(0))),
                source[role],
              );
              expect(
                glyphs(tester.renderObject<RenderParagraph>(labels.at(1))),
                target[role],
              );
            }
            frames++;
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(frames, inExclusiveRange(3, 120));
        }

        await checkFrames();
        await tester.pumpAndSettle();
        tester.state<_HarnessState>(find.byType(_Harness)).back();
        await tester.pump();
        await tester.pump();
        await checkFrames();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('handoff never restores labels on a still-departing page', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    double opacity(CoverTextRole role, {required bool source}) => tester
        .widget<Opacity>(
          find
              .descendant(
                of: _label(role, source: source, skipOffstage: false),
                matching: find.byType(Opacity, skipOffstage: false),
                skipOffstage: false,
              )
              .first,
        )
        .opacity;
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pumpAndSettle();
    for (final role in CoverTextRole.values) {
      expect(opacity(role, source: true), 0);
      expect(opacity(role, source: false), 1);
    }
    tester.state<_HarnessState>(find.byType(_Harness)).back();
    await tester.pump();
    for (var frame = 0; frame < 100; frame++) {
      for (final role in CoverTextRole.values) {
        final target = _label(role, skipOffstage: false);
        if (target.evaluate().isNotEmpty) {
          expect(
            opacity(role, source: false),
            0,
            reason: 'departing text must stay hidden after its flight lands',
          );
        }
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (final role in CoverTextRole.values) {
      expect(opacity(role, source: true), 1);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('departing caption pixels stay absent after the return lands', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Harness());
    final state = tester.state<_HarnessState>(find.byType(_Harness));
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pumpAndSettle();
    state.back();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // Exercise the scroll handoff while the old page is still fading.
    finishReturningCoverOnScroll(
      tester.element(find.byType(SingleChildScrollView).first),
    );
    await tester.pump();
    expect(_flight(CoverTextRole.title), findsNothing);
    var sampled = 0;
    for (var frame = 0; frame < 90; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final target = _label(CoverTextRole.title, skipOffstage: false);
      if (_flight(CoverTextRole.title).evaluate().isNotEmpty ||
          target.evaluate().isEmpty) {
        continue;
      }
      final rect = tester.getRect(target).deflate(1);
      final dirtyPixels = await tester.runAsync(() async {
        final boundary =
            state.screen.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final pixels = data!.buffer.asUint8List();
          var dirty = 0;
          for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
            for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
              final offset = (y * image.width + x) * 4;
              if (pixels[offset] < 252 ||
                  pixels[offset + 1] < 252 ||
                  pixels[offset + 2] < 252) {
                dirty++;
              }
            }
          }
          return dirty;
        } finally {
          image.dispose();
        }
      });
      expect(dirtyPixels, 0, reason: 'old header text must not flash back in');
      sampled++;
    }
    expect(sampled, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

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
        Future<Map<String, Rect>> finishFlight(String artworkKey) async {
          final artwork = find.byKey(ValueKey(artworkKey));
          final last = <String, Rect>{};
          for (var frame = 0; frame < 240; frame++) {
            final parts = <String, Finder>{
              'artwork': artwork,
              for (final role in CoverTextRole.values) role.name: _flight(role),
            };
            if (parts.values.every((part) => part.evaluate().isEmpty)) break;
            for (final part in parts.entries) {
              if (part.value.evaluate().isNotEmpty) {
                last[part.key] = tester.getRect(part.value);
              }
            }
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(artwork, findsNothing);
          await tester.pumpAndSettle();
          return last;
        }

        void expectLanded(Rect flight, Rect endpoint) {
          expect((flight.topLeft - endpoint.topLeft).distance, lessThan(.2));
          expect(
            (flight.bottomRight - endpoint.bottomRight).distance,
            lessThan(.2),
          );
        }

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
        await tester.pump(const Duration(milliseconds: 84));
        expect(
          tester.getRect(_flight(CoverTextRole.title)),
          isNot(origin[CoverTextRole.title]),
        );
        final arrived = await finishFlight('cover-transition-flight');
        expectLanded(
          arrived['artwork']!,
          tester.getRect(find.byType(CoverTransitionTarget)),
        );
        for (final role in CoverTextRole.values) {
          expect(_flight(role), findsNothing);
          expectLanded(arrived[role.name]!, tester.getRect(_label(role)));
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
        final returned = await finishFlight('cover-transition-return-flight');
        expectLanded(
          returned['artwork']!,
          tester.getRect(find.byType(CoverTransitionSource)),
        );
        for (final role in CoverTextRole.values) {
          expect(_flight(role), findsNothing);
          expect(tester.getRect(_label(role, source: true)), origin[role]);
          expectLanded(returned[role.name]!, origin[role]!);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('rapid back and reopen preserve text position', (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 84));
    final before = tester.getRect(_flight(CoverTextRole.title));
    tester.state<_HarnessState>(find.byType(_Harness)).back();
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(_flight(CoverTextRole.title)), before);
    await tester.pump(const Duration(milliseconds: 80));
    final returning = tester.getRect(_flight(CoverTextRole.title));
    await tester.tap(find.byType(AppPlaylistCard));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(_flight(CoverTextRole.title)), returning);
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
