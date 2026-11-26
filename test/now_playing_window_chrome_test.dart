import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/theme/adaptive_contrast.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/updates/open_external.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';
import 'package:lazer_nextgen/widgets/window_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _actionsKey = ValueKey('desktop-player-actions');
const _searchKey = ValueKey('desktop-search-osu');
const _addKey = ValueKey('desktop-add-to-playlist');
const _downloadKey = ValueKey('desktop-download');
const _minimizeKey = ValueKey('window-title-minimize');
const _windowChannel = MethodChannel('window_manager');

class _LyricsState extends AppState {
  _LyricsState({this.paperSkin = false}) {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    titleBarStyle = DesktopTitleBarStyle.inline;
    // A paper skin paints no backdrop at all, so the page itself is the canvas.
    playerBackground = paperSkin
        ? AppBackgroundMode.off
        : AppBackgroundMode.solidColor;
    lyricControlsSeconds = 1;
    lyrics = const [
      LyricLine(Duration.zero, 'The first lyric'),
      LyricLine(Duration(seconds: 10), 'The second lyric'),
    ];
  }

  /// A skin that turns the album-colour flow off: the listening canvas then
  /// follows the app's own brightness instead of forcing itself dark, which is
  /// what flips the adaptive chrome ink.
  final bool paperSkin;

  @override
  LazerThemeTokens get activeTheme => paperSkin
      ? const LazerThemeTokens(
          id: 'fixture.paper',
          name: 'Paper',
          version: 1,
          backgroundPlayMode: 'off',
        )
      : LazerThemeTokens.mio;

  @override
  bool get playing => true;

  @override
  Track get current => const Track(
    id: 'window-chrome-test',
    title: 'Window chrome test',
    artist: 'Test artist',
    album: 'Test album',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  );

  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
}

class _ExternalProcess extends Fake implements Process {}

class _PlayerFrameHarness {
  _PlayerFrameHarness(
    this.tester, {
    this.reduceMotion = false,
    this.pageOffset = Offset.zero,
    this.television = false,
    this.windowDrag,
    this.chromeStyle = DesktopTitleBarStyle.inline,
    bool paperSkin = false,
  }) : state = _LyricsState(paperSkin: paperSkin) {
    state.titleBarStyle = chromeStyle;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _windowChannel,
      (call) async {
        windowCalls.add(call.method);
        // A window drag keeps the platform's modal move loop — and its channel
        // reply — open until the button comes up, exactly like the Windows
        // implementation, so the release never reaches the Flutter view.
        if (call.method == 'startDragging') await windowDrag?.future;
        return switch (call.method) {
          'isMaximized' || 'isFullScreen' => false,
          'isFocused' => true,
          _ => null,
        };
      },
    );
  }

  final WidgetTester tester;
  final bool reduceMotion;
  final Offset pageOffset;
  final bool television;
  final DesktopTitleBarStyle chromeStyle;

  /// When set, `startDragging` stays pending until the test releases the
  /// button the way the OS move loop would.
  final Completer<void>? windowDrag;
  final _LyricsState state;
  final open = ValueNotifier(true);
  final presentationActive = ValueNotifier(true);
  final windowCalls = <String>[];

  Future<void> mount() async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: WindowFrame(enabled: true, state: state, child: child!),
        ),
        home: ValueListenableBuilder<bool>(
          valueListenable: open,
          builder: (context, visible, _) => visible
              ? TvScope(
                  active: television,
                  child: Transform.translate(
                    offset: pageOffset,
                    child: NowPlayingPage(
                      state: state,
                      presentationActive: presentationActive,
                      onClose: () => open.value = false,
                    ),
                  ),
                )
              : const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    state.dispose();
    open.dispose();
    presentationActive.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _windowChannel,
      null,
    );
    tester.view.reset();
  }
}

bool _controlsVisible(WidgetTester tester) => tester
    .widget<DesktopNowPlaying>(find.byType(DesktopNowPlaying))
    .controlsVisible;

double _windowOpacity(WidgetTester tester) => tester
    .widget<Opacity>(find.byKey(const ValueKey('window-chrome-fade')))
    .opacity;

double _actionsOpacity(WidgetTester tester) => tester
    .widget<Opacity>(find.byKey(const ValueKey('window-chrome-actions-fade')))
    .opacity;

double _actionsTranslation(WidgetTester tester) => tester
    .widget<Transform>(
      find.byKey(const ValueKey('window-chrome-actions-slide')),
    )
    .transform
    .getTranslation()
    .x;

double _actionsWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(_actionsKey)).width;

Finder _actionAncestors(Type type) =>
    find.ancestor(of: find.byKey(_searchKey), matching: find.byType(type));

/// Whether two colours are the same ink, ignoring alpha.
///
/// `IconButton` paints the scheme colour at a slightly lower alpha than the
/// scheme holds, so the resolved glyph never compares equal to the raw token.
bool _sameInk(Color a, Color b) =>
    (a.r - b.r).abs() < .001 &&
    (a.g - b.g).abs() < .001 &&
    (a.b - b.b).abs() < .001;

/// WCAG relative contrast between two colours.
///
/// States what the fix is about — the back glyph reading against what is behind
/// it — instead of pinning one ink value that a theme change may move.
double _contrast(Color a, Color b) {
  double luminance(Color color) {
    double channel(double value) => value <= .03928
        ? value / 12.92
        : math.pow((value + .055) / 1.055, 2.4).toDouble();
    return .2126 * channel(color.r) +
        .7152 * channel(color.g) +
        .0722 * channel(color.b);
  }

  final double la = luminance(a);
  final double lb = luminance(b);
  return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
}

void _expectActionsInactive(WidgetTester tester) {
  expect(
    tester
        .widgetList<IgnorePointer>(_actionAncestors(IgnorePointer))
        .any((widget) => widget.ignoring),
    isTrue,
  );
  expect(
    tester
        .widgetList<ExcludeFocus>(_actionAncestors(ExcludeFocus))
        .any((widget) => widget.excluding),
    isTrue,
  );
  expect(
    tester
        .widgetList<ExcludeSemantics>(_actionAncestors(ExcludeSemantics))
        .any((widget) => widget.excluding),
    isTrue,
  );
  expect(find.byKey(_searchKey).hitTestable(), findsNothing);
}

void _expectCaptionAtRest(WidgetTester tester) {
  final minimize = tester.getRect(find.byKey(_minimizeKey));
  expect(_windowOpacity(tester), 1);
  expect(minimize.top, 12);
  expect(minimize.size, const Size(46, 40));
  expect(minimize.left, 1122);
  expect(tester.getTopRight(find.byType(WindowTitleArea)).dx, 1260);
  expect(find.byKey(_minimizeKey).hitTestable(), findsOneWidget);
}

/// The classic strip is a fixed band of window chrome: it keeps that band, and
/// its caption cluster, whatever the presented page decides to hide.
void _expectClassicCaption(WidgetTester tester) {
  final strip = tester.getRect(find.byType(WindowTitleArea));
  expect(strip.top, 0);
  expect(strip.height, kWindowTitleAreaHeight);
  // The cluster stays flush to the strip's trailing edge, three buttons wide.
  final close = tester.getRect(
    find.byKey(const ValueKey('window-title-close')),
  );
  expect(close.right, strip.right);
  expect(close.height, kWindowTitleAreaHeight);
  expect(find.byKey(_minimizeKey).hitTestable(), findsOneWidget);
}

void _expectActionsAtRest(WidgetTester tester) {
  final rect = tester.getRect(find.byKey(_actionsKey));
  expect(rect.top, 12);
  expect(rect.right, 1122);
  expect(rect.width, closeTo(138, .05));
  expect(rect.height, 40);
  expect(tester.getSize(find.byKey(_searchKey)), const Size(46, 40));
  expect(tester.getSize(find.byKey(_addKey)), const Size(46, 40));
  expect(tester.getSize(find.byKey(_downloadKey)), const Size(46, 40));
  expect(_actionsOpacity(tester), closeTo(1, .0001));
  expect(_actionsTranslation(tester), closeTo(0, .02));
}

/// The one floating capsule: the caption buttons, then the player's action cells.
///
/// The way back is *not* on capsule material any more — it takes the listening
/// canvas's adaptive ink instead (see the two ink tests below). It is still
/// asserted to be on the row and reachable, just not behind a plate.
void _expectSingleSurface(WidgetTester tester, {double actionWidth = 138}) {
  final Finder surfaces = find.byType(WindowChromeSurface);
  expect(surfaces, findsOneWidget);
  // The trailing pill: caption buttons, then the player's action cells.
  final Rect surfaceRect = tester.getRect(surfaces);
  expect(surfaceRect.top, 12);
  expect(surfaceRect.right, 1260);
  expect(surfaceRect.width, closeTo(138 + actionWidth, .05));
  expect(surfaceRect.height, 40);
  for (final element in surfaces.evaluate()) {
    // Inline chrome paints the same material as the phone's navigation capsule:
    // a theme-accent tint at the configured opacity over a backdrop blur, with
    // no hairline of its own.
    final glass = tester.widget<AppleGlass>(
      find
          .descendant(
            of: find.byWidget(element.widget),
            matching: find.byType(AppleGlass),
          )
          .first,
    );
    expect(
      glass.color,
      windowChromeTint(
        AppleSemanticColors.of(element),
        opacity: kWindowChromeOpacityDefault,
      ),
    );
    expect(glass.blurSigma, kWindowChromeBlurDefault);
    expect(glass.borderRadius, BorderRadius.circular(20));
    expect(glass.border, isNull);
  }
}

void _expectActionGroup(WidgetTester tester) {
  final search = tester.getRect(find.byKey(_searchKey));
  final add = tester.getRect(find.byKey(_addKey));
  final download = tester.getRect(find.byKey(_downloadKey));
  expect(add.center.dx - search.center.dx, closeTo(46, .0001));
  expect(download.center.dx - add.center.dx, closeTo(46, .0001));
  for (final rect in [search, add, download]) {
    expect(rect.width, closeTo(46, .0001));
    expect(rect.height, closeTo(40, .0001));
    expect(rect.center.dy, 32);
  }
  for (var index = 0; index < 3; index++) {
    expect(
      find.byKey(ValueKey('window-chrome-action-slide-$index')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('window-chrome-action-fade-$index')),
      findsNothing,
    );
  }
}

void _expectCollapseAtRest(WidgetTester tester) {
  final back = find.byKey(const ValueKey('desktop-close'));
  final rect = tester.getRect(back);
  expect(rect.topLeft, const Offset(16, 12));
  expect(rect.size, const Size(46, 40));
  expect(rect.center.dy, 32);
  expect(back.hitTestable(), findsOneWidget);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'lyrics actions move as one group inside the extending caption capsule',
    (tester) async {
      final harness = _PlayerFrameHarness(tester);
      final previousStart = startExternalProcess;
      final searches = <Uri>[];
      startExternalProcess =
          (
            String executable,
            List<String> arguments, {
            ProcessStartMode mode = ProcessStartMode.normal,
          }) async {
            searches.add(Uri.parse(arguments.last));
            return _ExternalProcess();
          };
      try {
        await harness.mount();
        final player = find.byType(DesktopNowPlaying);
        final lyrics = find.byKey(
          const ValueKey('desktop-lyrics-window-chrome-test'),
        );
        final initialPlayerTop = tester.getTopLeft(player).dy;
        final initialLyricsTop = tester.getTopLeft(lyrics).dy;
        expect(_controlsVisible(tester), isTrue);
        _expectCaptionAtRest(tester);
        expect(_actionsWidth(tester), 0);
        expect(tester.getTopLeft(find.byKey(_actionsKey)).dy, 12);
        expect(tester.getTopRight(find.byKey(_actionsKey)).dx, 1122);
        _expectActionsInactive(tester);
        _expectSingleSurface(tester, actionWidth: 0);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('desktop-close'))).dy,
          12,
        );
        expect(
          // The frame no longer fabricates a top inset for Inline chrome: the
          // player clears the floating capsule with its own header band.
          MediaQuery.paddingOf(tester.element(find.byType(NowPlayingPage))).top,
          0,
        );

        await tester.pump(const Duration(milliseconds: 120));
        _expectCaptionAtRest(tester);
        expect(_actionsWidth(tester), inExclusiveRange(0, 138));
        expect(_actionsOpacity(tester), inExclusiveRange(0, 1));
        expect(_actionsTranslation(tester), inExclusiveRange(0, 138));
        _expectActionGroup(tester);
        _expectSingleSurface(tester, actionWidth: _actionsWidth(tester));
        expect(tester.getTopLeft(find.byKey(_actionsKey)).dy, 12);
        expect(tester.getTopRight(find.byKey(_actionsKey)).dx, 1122);

        await tester.pump(const Duration(milliseconds: 750));
        expect(_controlsVisible(tester), isTrue);
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);
        _expectSingleSurface(tester);
        _expectActionGroup(tester);
        expect(tester.getTopLeft(player).dy, initialPlayerTop);
        expect(tester.getTopLeft(lyrics).dy, initialLyricsTop);
        _expectCollapseAtRest(tester);

        await tester.pump(const Duration(milliseconds: 130));
        expect(_controlsVisible(tester), isFalse);
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);
        _expectCollapseAtRest(tester);
        expect(find.byKey(_searchKey).hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(_searchKey));
        await tester.pump();
        expect(searches, hasLength(1));
        expect(searches.single.host, 'osu.ppy.sh');
        expect(
          searches.single.queryParameters['q'],
          'Test artist Window chrome test',
        );
        expect(_controlsVisible(tester), isTrue);
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);

        await tester.tap(find.byKey(_minimizeKey));
        await tester.pump();
        expect(
          harness.windowCalls.where((call) => call == 'minimize'),
          hasLength(1),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(_controlsVisible(tester), isFalse);
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);
        expect(tester.getTopLeft(player).dy, initialPlayerTop);
        expect(tester.getTopLeft(lyrics).dy, initialLyricsTop);
        expect(tester.takeException(), isNull);
      } finally {
        startExternalProcess = previousStart;
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a classic title bar keeps its band while the player idles out', (
    tester,
  ) async {
    final harness = _PlayerFrameHarness(
      tester,
      chromeStyle: DesktopTitleBarStyle.classic,
    );
    try {
      await harness.mount();
      await tester.pump();
      final player = find.byType(NowPlayingPage);
      // The strip owns a real band: the page starts below it.
      expect(tester.getTopLeft(player).dy, kWindowTitleAreaHeight);
      expect(_controlsVisible(tester), isTrue);
      _expectClassicCaption(tester);

      // The idle countdown folds the dock away. It may not take the window's
      // own strip with it, nor move the page up into the strip's band.
      await tester.pump(const Duration(seconds: 2));
      expect(_controlsVisible(tester), isFalse);
      expect(tester.getTopLeft(player).dy, kWindowTitleAreaHeight);
      _expectClassicCaption(tester);
      await tester.tap(find.byKey(_minimizeKey));
      await tester.pump();
      expect(
        harness.windowCalls.where((call) => call == 'minimize'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the classic title bar leaves the player capsule to the page', (
    tester,
  ) async {
    final harness = _PlayerFrameHarness(
      tester,
      chromeStyle: DesktopTitleBarStyle.classic,
    );
    try {
      await harness.mount();
      // The frame reads the window's native state in a zero-delay timer when it
      // mounts; give that frame a duration so it lands before the assertions.
      await tester.pump(const Duration(milliseconds: 16));
      // One capsule on screen, painted by the page: under the classic strip
      // the window owns no capsule of its own. It is the player's own action
      // row that sits on it.
      expect(find.byType(WindowChromeSurface), findsOneWidget);
      final Finder capsule = find.byKey(_actionsKey);
      expect(tester.widget(capsule), isA<WindowChromeSurface>());
      final Rect rect = tester.getRect(capsule);
      expect(rect.height, kWindowChromeHeight);
      expect(rect.width, closeTo(kWindowChromeButtonWidth * 3, .05));
      expect(rect.right, 1280 - kWindowChromeEnd);
      // It sits on the header row's centre line, level with the page's own
      // back control, instead of inventing a second row.
      expect(
        rect.center.dy,
        tester.getCenter(find.byKey(const ValueKey('desktop-close'))).dy,
      );
      // The capsule wears the window's theme, not the player canvas's forced
      // dark one: switching title bar styles must not flip one capsule from
      // white glass to dark glass on the same page.
      expect(
        Theme.of(tester.element(capsule)).brightness,
        Theme.of(tester.element(find.byType(WindowTitleArea))).brightness,
      );
      // Same material as the capsule the frame floats in Inline mode: one
      // pill radius, the listener's tint at the configured opacity, the
      // backdrop blur and no hairline ring.
      final AppleGlass glass = tester.widget<AppleGlass>(
        find.descendant(of: capsule, matching: find.byType(AppleGlass)).first,
      );
      expect(
        glass.borderRadius,
        BorderRadius.circular(kWindowChromeHeight / 2),
      );
      expect(glass.border, isNull);
      expect(
        glass.color,
        windowChromeTint(
          AppleSemanticColors.of(tester.element(capsule)),
          opacity: kWindowChromeOpacityDefault,
        ),
      );
      expect(glass.blurSigma, kWindowChromeBlurDefault);
      // Every action takes a capsule cell and the capsule's ink, and the pill
      // is the surface those cells paint on.
      for (final Key key in <Key>[_searchKey, _addKey, _downloadKey]) {
        expect(
          find.descendant(of: capsule, matching: find.byKey(key)),
          findsOneWidget,
        );
        expect(tester.getSize(find.byKey(key)), const Size(46, 40));
        expect(tester.getRect(find.byKey(key)).center.dy, rect.center.dy);
      }
      expect(find.byKey(_actionsKey), findsOneWidget);
      expect(tester.getSize(find.byKey(_actionsKey)), rect.size);
      expect(find.byKey(_searchKey).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the page capsule follows the listener capsule settings', (
    tester,
  ) async {
    const Color custom = Color(0xFF3366FF);
    final harness = _PlayerFrameHarness(
      tester,
      chromeStyle: DesktopTitleBarStyle.classic,
    );
    Finder capsuleGlass() => find.descendant(
      of: find.byKey(_actionsKey),
      matching: find.byType(AppleGlass),
    );
    try {
      await harness.mount();
      await tester.pump();
      await harness.state.setWindowChromeColor(custom);
      await harness.state.setWindowChromeOpacity(.5);
      await harness.state.setWindowChromeBlur(24);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppleGlass>(capsuleGlass()).color,
        custom.withValues(alpha: .5),
      );
      expect(tester.widget<AppleGlass>(capsuleGlass()).blurSigma, 24);

      // Blur off paints the same tint without a backdrop filter at all.
      await harness.state.setWindowChromeBlurEnabled(false);
      await tester.pumpAndSettle();
      expect(capsuleGlass(), findsNothing);
      final Finder tinted = find.descendant(
        of: find.byKey(_actionsKey),
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  custom.withValues(alpha: .5),
        ),
      );
      expect(tinted, findsOneWidget);
      final DecoratedBox box = tester.widget<DecoratedBox>(tinted);
      expect(
        (box.decoration as BoxDecoration).color,
        custom.withValues(alpha: .5),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the player backdrop token is dark wherever art is painted', (
    tester,
  ) async {
    final harness = _PlayerFrameHarness(tester);
    try {
      await harness.mount();
      await tester.pump(const Duration(seconds: 1));
      final BuildContext context = tester.element(
        find.byKey(const ValueKey('desktop-close')),
      );
      // The contract the adaptive ink rests on. These used to resolve from
      // `AppleSemanticColors.background`, which describes the card surface the
      // chrome theme is built from — white in the Mio player while the canvas
      // underneath is cover art. That mismatch is what made the arrow black on
      // black, so pin the mapping itself rather than one theme's colours.
      for (final mode in <AppBackgroundMode>[
        AppBackgroundMode.solidColor,
        AppBackgroundMode.customImage,
        AppBackgroundMode.windowsMica,
        AppBackgroundMode.nowPlayingStatic,
        AppBackgroundMode.nowPlayingDynamic,
      ]) {
        expect(
          playerBackdropInk(context, mode).computeLuminance(),
          lessThan(.2),
          reason: '$mode composes over a dark edge',
        );
      }
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the back command adapts its ink to the listening canvas', (
    tester,
  ) async {
    final harness = _PlayerFrameHarness(tester);
    try {
      await harness.mount();
      await tester.pump(const Duration(seconds: 1));

      final Finder back = find.byKey(const ValueKey('desktop-close'));
      // No plate behind it: the corner of the cover keeps showing the artwork.
      expect(
        find.ancestor(of: back, matching: find.byType(WindowChromeSurface)),
        findsNothing,
        reason: 'a second capsule in the corner is worse than the problem',
      );

      final Icon glyph = tester.widget<Icon>(
        find.descendant(of: back, matching: find.byType(Icon)),
      );
      final BuildContext page = tester.element(back);
      final Color ink = glyph.color ?? IconTheme.of(page).color!;
      // The canvas the glyph is actually on: the composed player backdrop, not
      // the chrome theme's card surface.
      final Color canvas = playerBackdropInk(
        page,
        harness.state.playerBackground,
      );
      expect(
        canvas.computeLuminance(),
        lessThan(.2),
        reason: 'the Mio player composes its canvas over dark art',
      );

      // The ink is decided by that canvas, exactly like the transport and the
      // pane tabs: dark art resolves the arrow to near-white. It used to inherit
      // the (light) chrome theme's card surface instead — white here — and went
      // black on black.
      expect(
        _sameInk(ink, contrastingLabel(canvas)),
        isTrue,
        reason: 'the back command has to follow the adaptive player ink',
      );
      expect(
        _contrast(ink, canvas),
        greaterThanOrEqualTo(3),
        reason: 'legible against the canvas it sits on',
      );

      // One shadow, in the direction that helps: a dark glow under light ink, a
      // light glow under dark ink. That is what carries it across a busy cover.
      expect(glyph.shadows, hasLength(1));
      final Shadow shadow = glyph.shadows!.single;
      expect(shadow.blurRadius, inInclusiveRange(2, 6));
      final bool lightInk = ink.computeLuminance() > .5;
      final bool lightGlow = shadow.color.computeLuminance() > .5;
      expect(
        lightGlow,
        !lightInk,
        reason: 'the glow has to oppose the ink, not match it',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a light canvas flips the back command to dark ink', (
    tester,
  ) async {
    final harness = _PlayerFrameHarness(tester, paperSkin: true);
    try {
      await harness.mount();
      await tester.pump(const Duration(seconds: 1));

      final Finder back = find.byKey(const ValueKey('desktop-close'));
      final Icon glyph = tester.widget<Icon>(
        find.descendant(of: back, matching: find.byType(Icon)),
      );
      final BuildContext page = tester.element(back);
      // A skin with the colour flow off paints no backdrop, so the canvas is the
      // app's own surface — the light half of the adaptive rule.
      final Color canvas = playerBackdropInk(
        page,
        harness.state.playerBackground,
      );
      final Color ink = glyph.color ?? IconTheme.of(page).color!;
      expect(_sameInk(ink, contrastingLabel(canvas)), isTrue);
      expect(_contrast(ink, canvas), greaterThanOrEqualTo(3));
      // The shadow flips with the ink, so the glyph still survives a bright or a
      // busy cover on either canvas.
      final bool lightInk = ink.computeLuminance() > .5;
      expect(glyph.shadows!.single.color.computeLuminance() > .5, !lightInk);
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'both player controls stay aligned to the caption as the page slides',
    (tester) async {
      final harness = _PlayerFrameHarness(
        tester,
        pageOffset: const Offset(0, 200),
      );
      final previousStart = startExternalProcess;
      var searches = 0;
      startExternalProcess =
          (
            String executable,
            List<String> arguments, {
            ProcessStartMode mode = ProcessStartMode.normal,
          }) async {
            searches++;
            return _ExternalProcess();
          };
      try {
        await harness.mount();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getTopLeft(find.byType(NowPlayingPage)).dy, 200);
        _expectCollapseAtRest(tester);
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);
        _expectSingleSurface(tester);
        expect(find.byKey(_searchKey).hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(_searchKey));
        await tester.pump();
        expect(searches, 1);
        expect(
          harness.windowCalls.where((call) => call == 'startDragging'),
          isEmpty,
        );
        await tester.tap(find.byKey(_minimizeKey));
        await tester.pump();
        expect(
          harness.windowCalls.where((call) => call == 'minimize'),
          hasLength(1),
        );
        await tester.tap(find.byKey(const ValueKey('desktop-close')));
        await tester.pump();
        expect(harness.open.value, isFalse);
        expect(find.byType(NowPlayingPage), findsNothing);
        _expectCaptionAtRest(tester);
        expect(tester.takeException(), isNull);
      } finally {
        startExternalProcess = previousStart;
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'closing disables actions immediately and preserves caption interaction',
    (tester) async {
      final harness = _PlayerFrameHarness(tester);
      try {
        await harness.mount();
        await tester.pump(const Duration(seconds: 1));
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);

        harness.presentationActive.value = false;
        await tester.pump();
        expect(_actionsWidth(tester), 138);
        _expectActionsInactive(tester);
        _expectCaptionAtRest(tester);
        await tester.pump(const Duration(milliseconds: 120));
        expect(_actionsWidth(tester), inExclusiveRange(0, 138));
        _expectActionsInactive(tester);
        _expectCaptionAtRest(tester);
        _expectSingleSurface(tester, actionWidth: _actionsWidth(tester));

        await tester.pump(const Duration(seconds: 1));
        expect(_actionsWidth(tester), 0);
        _expectCaptionAtRest(tester);
        _expectSingleSurface(tester, actionWidth: 0);
        final hold = await tester.startGesture(
          tester.getCenter(find.byKey(_minimizeKey)),
        );
        await tester.pump(const Duration(seconds: 3));
        expect(
          harness.windowCalls.where((call) => call == 'minimize'),
          isEmpty,
        );
        await hold.up();
        await tester.pump();
        expect(
          harness.windowCalls.where((call) => call == 'minimize'),
          hasLength(1),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(harness.open.value, isFalse);
        expect(find.byType(NowPlayingPage), findsNothing);
        _expectCaptionAtRest(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'reopening a cached player reverses emerging actions without a jump',
    (tester) async {
      final harness = _PlayerFrameHarness(tester);
      try {
        await harness.mount();
        await tester.pump(const Duration(seconds: 1));
        final page = find.byType(NowPlayingPage);
        final pageState = tester.state(page);
        _expectActionsAtRest(tester);

        harness.presentationActive.value = false;
        await tester.pump();
        _expectActionsInactive(tester);
        await tester.pump(const Duration(milliseconds: 120));
        expect(tester.state(page), same(pageState));
        final departingWidth = _actionsWidth(tester);
        final departingOpacity = _actionsOpacity(tester);
        final departingTranslation = _actionsTranslation(tester);
        expect(departingWidth, inExclusiveRange(0, 138));

        harness.presentationActive.value = true;
        await tester.pump();
        expect(tester.state(page), same(pageState));
        expect(_actionsWidth(tester), closeTo(departingWidth, .0001));
        expect(_actionsOpacity(tester), closeTo(departingOpacity, .0001));
        expect(
          _actionsTranslation(tester),
          closeTo(departingTranslation, .0001),
        );
        _expectCaptionAtRest(tester);
        _expectSingleSurface(tester, actionWidth: _actionsWidth(tester));

        await tester.pump(const Duration(milliseconds: 32));
        expect(_actionsWidth(tester), inExclusiveRange(0, 138));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.state(page), same(pageState));
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);
        _expectSingleSurface(tester);
        _expectCollapseAtRest(tester);
        expect(find.byKey(_searchKey).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'modal routes hide actions without moving the fixed window caption',
    (tester) async {
      final harness = _PlayerFrameHarness(tester);
      try {
        await harness.mount();
        await tester.pump(const Duration(seconds: 1));
        _expectActionsAtRest(tester);
        final originalRect = tester.getRect(find.byKey(_actionsKey));
        final pageContext = tester.element(find.byType(NowPlayingPage));
        final dialog = showDialog<void>(
          context: pageContext,
          builder: (context) => const AlertDialog(
            title: Text('Modal action regression'),
            content: Text('Player actions must stay behind this dialog.'),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.text('Modal action regression'), findsOneWidget);
        expect(find.byKey(_actionsKey), findsNothing);
        expect(find.byKey(_searchKey).hitTestable(), findsNothing);
        expect(
          find.byKey(const ValueKey('desktop-close')).hitTestable(),
          findsNothing,
        );
        final hiddenActions = find.byKey(_actionsKey, skipOffstage: false);
        expect(hiddenActions, findsOneWidget);
        expect(tester.getSize(hiddenActions).width, inExclusiveRange(0, 138));
        _expectSingleSurface(
          tester,
          actionWidth: tester.getSize(hiddenActions).width,
        );
        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(
                      of: hiddenActions,
                      matching: find.byType(IgnorePointer, skipOffstage: false),
                    )
                    .first,
              )
              .ignoring,
          isTrue,
        );
        expect(
          tester
              .widget<ExcludeFocus>(
                find
                    .ancestor(
                      of: hiddenActions,
                      matching: find.byType(ExcludeFocus, skipOffstage: false),
                    )
                    .first,
              )
              .excluding,
          isTrue,
        );
        expect(
          tester
              .widget<ExcludeSemantics>(
                find
                    .ancestor(
                      of: hiddenActions,
                      matching: find.byType(
                        ExcludeSemantics,
                        skipOffstage: false,
                      ),
                    )
                    .first,
              )
              .excluding,
          isTrue,
        );
        _expectCaptionAtRest(tester);
        await tester.tap(find.byKey(_minimizeKey));
        await tester.pump();
        expect(
          harness.windowCalls.where((call) => call == 'minimize'),
          hasLength(1),
        );
        await tester.pump(const Duration(seconds: 1));
        // The dialog covers the player, so the page's own controls are gone with
        // it; the window's caption capsule stays where it is.
        _expectSingleSurface(tester, actionWidth: 0);

        Navigator.of(pageContext).pop();
        await tester.pump();
        await tester.pump();
        await dialog;
        _expectCaptionAtRest(tester);
        expect(_actionsWidth(tester), 0);
        await tester.pump(const Duration(milliseconds: 120));
        expect(_actionsWidth(tester), inExclusiveRange(0, 138));
        _expectSingleSurface(tester, actionWidth: _actionsWidth(tester));
        _expectActionGroup(tester);
        await tester.pump(const Duration(seconds: 1));
        _expectActionsAtRest(tester);
        _expectSingleSurface(tester);
        _expectCollapseAtRest(tester);
        expect(tester.getRect(find.byKey(_actionsKey)), originalRect);
        expect(find.byKey(_searchKey).hitTestable(), findsOneWidget);

        final reversingDialog = showDialog<void>(
          context: pageContext,
          builder: (context) => const AlertDialog(title: Text('Reverse modal')),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        // The trailing pill only: the back command went with the dialog-covering
        // page, and the assertion is about the caption shell's own spring.
        final returningShellWidth = tester
            .getSize(find.byType(WindowChromeSurface))
            .width;
        expect(returningShellWidth, inExclusiveRange(138, 276));
        Navigator.of(pageContext).pop();
        await tester.pump();
        await tester.pump();
        await reversingDialog;
        expect(
          tester.getSize(find.byType(WindowChromeSurface)).width,
          closeTo(returningShellWidth, .0001),
          reason: 'Dismissing a modal retargets the current shell spring.',
        );
        _expectCaptionAtRest(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getRect(find.byKey(_actionsKey)), originalRect);
        _expectSingleSurface(tester);
        _expectCollapseAtRest(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'TV keeps normal action controls inside the safely inset player toolbar',
    (tester) async {
      final harness = _PlayerFrameHarness(tester, television: true);
      try {
        await harness.mount();
        final actions = find.byKey(_actionsKey);
        expect(actions, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(DesktopNowPlaying),
            matching: actions,
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(WindowChromeActions),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is OverlayPortal &&
                  widget.overlayLocation == OverlayChildLocation.rootOverlay,
            ),
          ),
          findsNothing,
        );
        final toolbarRect = tester.getRect(actions);
        expect(toolbarRect.top, greaterThanOrEqualTo(56));
        expect(toolbarRect.right, lessThanOrEqualTo(1280 - 24));
        for (final key in [_searchKey, _addKey, _downloadKey]) {
          final button = find.byKey(key);
          expect(
            find.descendant(of: actions, matching: button),
            findsOneWidget,
          );
          final size = tester.getSize(button);
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        for (var index = 0; index < 3; index++) {
          expect(
            find.byKey(ValueKey('window-chrome-action-slide-$index')),
            findsNothing,
          );
        }
        expect(
          find.byKey(const ValueKey('window-chrome-actions-slide')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('window-chrome-actions-fade')),
          findsNothing,
        );
        final back = find.byKey(const ValueKey('desktop-close'));
        expect(
          find.descendant(of: find.byType(DesktopNowPlaying), matching: back),
          findsOneWidget,
        );
        expect(tester.getSize(back).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(back).height, greaterThanOrEqualTo(48));
        expect(find.byKey(_searchKey).hitTestable(), findsOneWidget);
        _expectCaptionAtRest(tester);
        await tester.pump(const Duration(milliseconds: 120));
        expect(tester.getRect(actions), toolbarRect);
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getRect(actions), toolbarRect);
        _expectCaptionAtRest(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'reduced motion reveals actions immediately without moving the caption',
    (tester) async {
      final harness = _PlayerFrameHarness(tester, reduceMotion: true);
      try {
        await harness.mount();
        expect(_controlsVisible(tester), isTrue);
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);
        _expectSingleSurface(tester);
        _expectCollapseAtRest(tester);
        expect(find.byKey(_searchKey).hitTestable(), findsOneWidget);

        await tester.pump(const Duration(seconds: 1));
        expect(_controlsVisible(tester), isFalse);
        _expectCaptionAtRest(tester);
        _expectActionsAtRest(tester);
        harness.presentationActive.value = false;
        await tester.pump();
        expect(_actionsWidth(tester), 0);
        _expectActionsInactive(tester);
        _expectCaptionAtRest(tester);
        _expectSingleSurface(tester, actionWidth: 0);

        harness.presentationActive.value = true;
        await tester.pump();
        _expectActionsAtRest(tester);
        _expectSingleSurface(tester);
        _expectCollapseAtRest(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump();
        expect(find.byType(NowPlayingPage), findsNothing);
        _expectCaptionAtRest(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the idle countdown restarts after an inactive presentation consumes it',
    (tester) async {
      final harness = _PlayerFrameHarness(tester);
      try {
        await harness.mount();
        expect(_controlsVisible(tester), isTrue);
        // A page that is not presented may not hide its dock. The pending
        // countdown expires in that window instead of hiding, which used to be
        // the end of it: nothing started another one, so the dock stayed on
        // screen for the rest of the session.
        harness.presentationActive.value = false;
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(_controlsVisible(tester), isTrue);
        harness.presentationActive.value = true;
        await tester.pump();
        expect(_controlsVisible(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 1));
        expect(_controlsVisible(tester), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the press that starts a window drag stops holding the dock awake',
    (tester) async {
      final drag = Completer<void>();
      final harness = _PlayerFrameHarness(tester, windowDrag: drag);
      try {
        await harness.mount();
        expect(_controlsVisible(tester), isTrue);
        // Grab the page's own title band and move past the drag slop. From
        // here the platform move loop owns the pointer, so the release of this
        // press is consumed by the window instead of the view.
        final press = await tester.startGesture(const Offset(320, 20));
        await press.moveBy(const Offset(36, 10));
        await tester.pump();
        expect(
          harness.windowCalls.where((call) => call == 'startDragging'),
          hasLength(1),
        );
        await tester.pump(const Duration(seconds: 3));
        expect(_controlsVisible(tester), isTrue);

        // The button comes up inside the OS move loop: the channel reply is
        // the only signal this view ever gets for that release.
        drag.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 1));
        expect(_controlsVisible(tester), isFalse);
        expect(tester.takeException(), isNull);
        await press.up();
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
