import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/song_comments_controller.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';
import 'package:lazer_nextgen/widgets/window_frame.dart';
import 'package:lazer_nextgen/widgets/song_comments_view.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Track(
  id: 'layout',
  title: '午前1時39分に死にたい feat. 初音ミク — a long track title',
  translatedTitle: '想在凌晨 1:39 分死去',
  artist: 'Magens',
  album: '午前1時39分に死にたい feat. 初音ミク',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const _screenshotTrack = Track(
  id: 'layout-light-years-away',
  title: 'Light Years Away (From Hardcore Utopia 4)',
  translatedTitle: '光年之外',
  artist: 'Synthion',
  album: 'Light Years Away (From Hardcore Utopia 4)',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _PaneState extends AppState {
  final played = <int>[];

  @override
  List<Track> get queue => const [_track];
  @override
  int get queueLength => 1;
  @override
  Track get current => _track;
  @override
  void playTrackAt(int index) => played.add(index);
}

class _PaneComments extends SongCommentsController {
  _PaneComments(AppState state) : super(state.catalog.connections);
  int refreshes = 0;

  @override
  Future<void> openSong(String id, {required int accountId}) async {
    trackId = id;
    notifyListeners();
  }

  @override
  Future<void> refresh() async => refreshes++;
}

Widget _withWindowChrome(WindowChromeController? controller, Widget child) =>
    controller == null
    ? child
    : WindowChromeScope(
        controller: controller,
        inline: true,
        reveal: const AlwaysStoppedAnimation<double>(0),
        child: child,
      );

Widget _host(
  AppState state, {
  bool controls = true,
  bool tv = false,
  double textScale = 1,
  Track track = _track,
  WindowChromeController? windowChromeController,
}) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  home: _withWindowChrome(
    windowChromeController,
    TvScope(
      active: tv,
      child: MediaQuery(
        data: MediaQueryData(
          padding: EdgeInsets.only(
            top: windowChromeController == null ? 46 : 56,
          ),
          viewPadding: EdgeInsets.only(
            top: windowChromeController == null ? 46 : 56,
          ),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: DesktopNowPlaying(
            state: state,
            track: track,
            artwork: const ColoredBox(
              key: ValueKey('layout-art'),
              color: Colors.blue,
            ),
            lyrics: const ColoredBox(
              key: ValueKey('layout-lyrics'),
              color: Colors.red,
            ),
            comments: const SizedBox(),
            queue: const SizedBox(),
            pane: DesktopNowPlayingPane.lyrics,
            onPaneChanged: (_) {},
            onBack: () {},
            onSaveArtwork: () {},
            onFullscreen: () {},
            controlsVisible: controls,
            onActivity: () {},
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final sample in [
    (style: DesktopTitleBarStyle.inline, tv: false),
    (style: DesktopTitleBarStyle.classic, tv: false),
    (style: DesktopTitleBarStyle.inline, tv: true),
  ]) {
    testWidgets('comments and queue clear the floating header: $sample', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const channel = MethodChannel('window_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'isMaximized' || 'isFullScreen' => false,
          'isFocused' => true,
          _ => null,
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final state = _PaneState()
        ..titleBarStyle = sample.style
        ..layoutStyle = AppLayoutStyle.desktop;
      final comments = _PaneComments(state);
      final source = ValueNotifier(true);
      final pane = ValueNotifier(DesktopNowPlayingPane.lyrics);
      addTearDown(state.dispose);
      addTearDown(comments.dispose);
      addTearDown(source.dispose);
      addTearDown(pane.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(brightness: Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: WindowFrame(enabled: true, state: state, child: child!),
          ),
          home: TvScope(
            active: sample.tv,
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  WindowChromeScope.maybeOf(context)!.attach(source);
                  return ValueListenableBuilder<DesktopNowPlayingPane>(
                    valueListenable: pane,
                    builder: (context, currentPane, _) => DesktopNowPlaying(
                      state: state,
                      track: _track,
                      artwork: const ColoredBox(
                        key: ValueKey('layout-art'),
                        color: Colors.blue,
                      ),
                      lyrics: const SizedBox.expand(),
                      comments: SongCommentsView(
                        state: state,
                        track: _track,
                        controller: comments,
                      ),
                      queue: PlaybackQueueView(state: state, showHeader: false),
                      pane: currentPane,
                      onPaneChanged: (value) => pane.value = value,
                      onBack: () {},
                      onSaveArtwork: () {},
                      onFullscreen: () {},
                      controlsVisible: true,
                      onActivity: () {},
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final artworkRect = tester.getRect(
        find.byKey(const ValueKey('layout-art')),
      );
      final actionsBottom = tester
          .getRect(find.byKey(const ValueKey('desktop-player-actions')))
          .bottom;
      final captionBottom = tester.getRect(find.byType(WindowTitleArea)).bottom;
      final headerBottom = actionsBottom > captionBottom
          ? actionsBottom
          : captionBottom;

      pane.value = DesktopNowPlayingPane.comments;
      await tester.pumpAndSettle();
      final refresh = find.byTooltip('刷新评论');
      expect(tester.getRect(refresh).top, greaterThanOrEqualTo(headerBottom));
      expect(refresh.hitTestable(), findsOneWidget);
      await tester.tap(refresh);
      await tester.pump();
      expect(comments.refreshes, 1);
      expect(
        tester.getRect(find.byKey(const ValueKey('layout-art'))),
        artworkRect,
      );

      pane.value = DesktopNowPlayingPane.queue;
      await tester.pumpAndSettle();
      final queueRow = find
          .descendant(
            of: find.byType(PlaybackQueueView),
            matching: find.byType(InkWell),
          )
          .first;
      final queueRect = tester.getRect(queueRow);
      expect(queueRect.top, greaterThanOrEqualTo(headerBottom));
      // Exercise the right edge which the floating action group used to cover.
      await tester.tapAt(Offset(queueRect.right - 16, queueRect.top + 20));
      await tester.pump();
      expect(state.played, [0]);
      expect(
        tester.getRect(find.byKey(const ValueKey('layout-art'))),
        artworkRect,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  for (final sample in [
    (size: const Size(1783, 974), inline: true),
    (size: const Size(1280, 800), inline: true),
    (size: const Size(1280, 800), inline: false),
  ]) {
    testWidgets('artwork and metadata stay vertically balanced: $sample', (
      tester,
    ) async {
      tester.view.physicalSize = sample.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      final chrome = sample.inline ? WindowChromeController() : null;
      if (chrome != null) addTearDown(chrome.dispose);

      // Check both settled states, including a reversal of the dock transition.
      for (final controls in [true, false, true]) {
        await tester.pumpWidget(
          _host(
            state,
            controls: controls,
            track: _screenshotTrack,
            windowChromeController: chrome,
          ),
        );
        await tester.pumpAndSettle();
        final art = tester.getRect(find.byKey(const ValueKey('layout-art')));
        final metadata = tester.getRect(
          find.byKey(const ValueKey('desktop-player-metadata')),
        );
        // Inline chrome floats over the page, so the listening canvas starts
        // below the capsule's band; the classic strip owns a real strip.
        final availableTop = sample.inline ? kInlineChromeInset : 46.0;
        final availableBottom = controls
            ? tester
                  .getRect(find.byKey(const ValueKey('desktop-dock-content')))
                  .top
            : sample.size.height;
        expect(
          art.top - availableTop,
          closeTo(
            availableBottom - metadata.bottom - kDesktopArtworkBottomInset,
            .5,
          ),
          reason:
              'The cover and its metadata should be centered with the '
              'desktop bottom inset while controls are '
              '${controls ? 'visible' : 'hidden'}.',
        );
        expect(art.width, closeTo(art.height, .1));
        expect(metadata.bottom, lessThanOrEqualTo(availableBottom));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('wide desktop prioritizes artwork without crowding metadata', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    final art = tester.getRect(find.byKey(const ValueKey('layout-art')));
    final lyrics = tester.getRect(find.byKey(const ValueKey('layout-lyrics')));
    expect(art.width, greaterThanOrEqualTo(350));
    expect(art.width, closeTo(art.height, .1));
    expect(art.right, lessThan(lyrics.left));
    expect(art.top, greaterThanOrEqualTo(46));
    final metadata = tester.getRect(
      find.byKey(const ValueKey('desktop-player-metadata')),
    );
    final dock = tester.getRect(
      find.byKey(const ValueKey('desktop-dock-content')),
    );
    expect(metadata.bottom, lessThanOrEqualTo(dock.top));
    expect(metadata.left, closeTo(art.left, .1));
    expect(
      tester.getCenter(find.byKey(const ValueKey('desktop-play-pause'))).dx,
      closeTo(640, .1),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('desktop-seek-bar'))).dx,
      closeTo(640, .1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final sample in [
    (size: const Size(800, 480), scale: 1.0, tv: false),
    (size: const Size(1280, 720), scale: 1.8, tv: false),
    (size: const Size(1280, 720), scale: 1.0, tv: true),
  ]) {
    testWidgets('compact and accessible layout stays usable: $sample', (
      tester,
    ) async {
      tester.view.physicalSize = sample.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        _host(state, tv: sample.tv, textScale: sample.scale),
      );
      await tester.pumpAndSettle();
      final art = tester.getRect(find.byKey(const ValueKey('layout-art')));
      // Fractional centering offsets can lose precision in global rect widths.
      expect(
        tester.getSize(find.byKey(const ValueKey('layout-art'))).width,
        greaterThanOrEqualTo(72),
      );
      expect(art.width, closeTo(art.height, .1));
      expect(
        find.byKey(const ValueKey('desktop-play-pause')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('hidden dock releases space and leaves no invisible controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    final visibleSize = tester.getSize(
      find.byKey(const ValueKey('layout-art')),
    );
    await tester.pumpWidget(_host(state, controls: false));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('layout-art'))).width,
      greaterThan(visibleSize.width),
    );
    expect(
      find.byKey(const ValueKey('desktop-play-pause')).hitTestable(),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
