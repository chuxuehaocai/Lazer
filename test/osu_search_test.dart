import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/player/osu_search.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';

const MethodChannel _updatesChannel = MethodChannel(
  'dev.naominet.lazer/updates',
);

const Track _encodedTrack = Track(
  id: 'encoded',
  title: '  星 #1 + été 100%  ',
  artist: '  初音ミク & A+B  ',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
  translatedTitle: 'Translated title',
);

const String _encodedUrl =
    'https://osu.ppy.sh/beatmapsets?q='
    '%E5%88%9D%E9%9F%B3%E3%83%9F%E3%82%AF+%26+A%2BB+'
    '%E6%98%9F+%231+%2B+%C3%A9t%C3%A9+100%25';

Track _track({
  String title = '',
  String artist = '',
  String? translatedTitle,
  List<ArtistRef> artists = const <ArtistRef>[],
}) => Track(
  id: 'test',
  title: title,
  artist: artist,
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
  translatedTitle: translatedTitle,
  artists: artists,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
}

void _mockExternalUrl(
  WidgetTester tester,
  TargetPlatform platform,
  Future<Object?> Function(MethodCall call) handler,
) {
  assert(debugDefaultTargetPlatformOverride == platform);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _updatesChannel,
    handler,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _updatesChannel,
      null,
    ),
  );
}

Widget _searchPage(Track? track) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (BuildContext context) => Center(
        child: TextButton(
          onPressed: () => unawaited(searchInOsu(context, track)),
          child: const Text('Search'),
        ),
      ),
    ),
  ),
);

Widget _desktopPage(AppState state, Track track) => MaterialApp(
  theme: buildLegacyTheme(),
  home: Scaffold(
    body: DesktopNowPlaying(
      state: state,
      track: track,
      artwork: const SizedBox.square(dimension: 120),
      lyrics: const SizedBox.shrink(),
      comments: const SizedBox.shrink(),
      queue: const SizedBox.shrink(),
      pane: DesktopNowPlayingPane.lyrics,
      onPaneChanged: (_) {},
      onBack: () {},
      onSaveArtwork: () {},
      onFullscreen: () {},
      controlsVisible: true,
      onActivity: () {},
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('osuBeatmapSearchUri', () {
    test('encodes Unicode and reserved characters once in a single query', () {
      final Uri uri = osuBeatmapSearchUri(_encodedTrack)!;

      expect(uri.toString(), _encodedUrl);
      expect(uri.scheme, 'https');
      expect(uri.host, 'osu.ppy.sh');
      expect(uri.path, '/beatmapsets');
      expect(uri.queryParameters, <String, String>{
        'q': '初音ミク & A+B 星 #1 + été 100%',
      });
      expect(uri.fragment, isEmpty);
    });

    test('uses either field alone and ignores unknown artist placeholders', () {
      expect(
        osuBeatmapSearchUri(_track(title: '  Song  '))!.queryParameters['q'],
        'Song',
      );
      expect(
        osuBeatmapSearchUri(_track(artist: '  Artist  '))!.queryParameters['q'],
        'Artist',
      );
      for (final String unknown in <String>['未知歌手', '未知艺术家']) {
        expect(
          osuBeatmapSearchUri(
            _track(title: '  Song  ', artist: ' $unknown '),
          )!.queryParameters['q'],
          'Song',
        );
      }
    });

    test('returns null when there is no searchable metadata', () {
      expect(osuBeatmapSearchUri(null), isNull);
      expect(osuBeatmapSearchUri(_track()), isNull);
      expect(osuBeatmapSearchUri(_track(title: '  ', artist: '\t')), isNull);
      for (final String unknown in <String>['未知歌手', '未知艺术家']) {
        expect(osuBeatmapSearchUri(_track(artist: unknown)), isNull);
      }
      expect(
        osuBeatmapSearchUri(_track(translatedTitle: 'Translation only')),
        isNull,
      );
    });

    test('uses the original title and the combined artist field', () {
      final Track track = _track(
        title: '原曲',
        translatedTitle: 'Translated song',
        artist: 'First Artist / 第二位',
        artists: const <ArtistRef>[
          ArtistRef(id: 1, name: 'First Artist'),
          ArtistRef(id: 2, name: '第二位'),
        ],
      );

      final Uri uri = osuBeatmapSearchUri(track)!;
      expect(uri.queryParameters['q'], 'First Artist / 第二位 原曲');
      expect(uri.queryParameters['q'], isNot(contains('Translated song')));
    });
  });

  group('searchInOsu', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      testWidgets('$platform opens the encoded URL without a dialog', (
        WidgetTester tester,
      ) async {
        final List<MethodCall> calls = <MethodCall>[];
        _mockExternalUrl(tester, platform, (MethodCall call) async {
          calls.add(call);
          return true;
        });
        await tester.pumpWidget(_searchPage(_encodedTrack));

        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();

        expect(calls, hasLength(1));
        expect(calls.single.method, 'openUrl');
        expect(calls.single.arguments, <String, Object>{'url': _encodedUrl});
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$platform shows a copyable link when opening fails', (
        WidgetTester tester,
      ) async {
        final List<MethodCall> calls = <MethodCall>[];
        final List<String> copied = <String>[];
        _mockExternalUrl(tester, platform, (MethodCall call) async {
          calls.add(call);
          return false;
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall call) async {
            if (call.method == 'Clipboard.setData') {
              final Map<Object?, Object?> data =
                  call.arguments as Map<Object?, Object?>;
              copied.add(data['text']! as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(_searchPage(_encodedTrack));

        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();

        expect(calls, hasLength(1));
        expect(calls.single.method, 'openUrl');
        expect(calls.single.arguments, <String, Object>{'url': _encodedUrl});
        expect(find.text('无法打开浏览器'), findsOneWidget);
        expect(find.text('请复制链接并在浏览器中打开。'), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        expect(find.text(_encodedUrl), findsOneWidget);

        await tester.tap(find.text('复制'));
        await tester.pumpAndSettle();

        expect(copied, <String>[_encodedUrl]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('链接已复制'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(platform));
    }

    testWidgets('a platform exception also shows the fallback dialog', (
      WidgetTester tester,
    ) async {
      _mockExternalUrl(tester, TargetPlatform.android, (MethodCall call) async {
        throw PlatformException(code: 'no_browser');
      });
      await tester.pumpWidget(_searchPage(_encodedTrack));

      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();

      expect(find.text('无法打开浏览器'), findsOneWidget);
      expect(find.text(_encodedUrl), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets(
      'empty metadata does not invoke the platform or show a dialog',
      (WidgetTester tester) async {
        final List<MethodCall> calls = <MethodCall>[];
        _mockExternalUrl(tester, TargetPlatform.android, (
          MethodCall call,
        ) async {
          calls.add(call);
          return false;
        });
        await tester.pumpWidget(_searchPage(_track(artist: '未知歌手')));

        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();

        expect(calls, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('a failed launch after the page is disposed shows no dialog', (
      WidgetTester tester,
    ) async {
      final Completer<Object?> result = Completer<Object?>();
      _mockExternalUrl(tester, TargetPlatform.android, (MethodCall call) {
        return result.future;
      });
      await tester.pumpWidget(_searchPage(_encodedTrack));
      await tester.tap(find.text('Search'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      result.complete(false);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('desktop search button', () {
    testWidgets(
      'is visible and keyboard activation follows the current track',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final List<MethodCall> calls = <MethodCall>[];
        _mockExternalUrl(tester, TargetPlatform.android, (
          MethodCall call,
        ) async {
          calls.add(call);
          return true;
        });
        final AppState state = AppState(catalog: _Catalog());
        addTearDown(state.dispose);
        final Track next = _track(
          title: 'Second + Song',
          artist: 'Next Artist',
        );
        state.playQueue(<Track>[_encodedTrack, next]);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLegacyTheme(),
            home: NowPlayingPage(state: state),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final Finder button = find.byKey(const ValueKey('desktop-search-osu'));
        expect(button, findsOneWidget);
        expect(find.byTooltip('在 osu! 中搜索'), findsOneWidget);
        expect(
          tester.widget<AccessibleIconButton>(button).onPressed,
          isNotNull,
        );
        final Finder icon = find.descendant(
          of: button,
          matching: find.byIcon(Icons.search_rounded),
        );
        final FocusNode focus = Focus.of(tester.element(icon));
        final Finder closeIcon = find.descendant(
          of: find.byKey(const ValueKey('desktop-close')),
          matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
        );
        final FocusNode closeFocus = Focus.of(tester.element(closeIcon));
        closeFocus.requestFocus();
        await tester.pump();
        expect(closeFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(calls, hasLength(1));
        expect(calls.single.method, 'openUrl');
        expect(calls.single.arguments, <String, Object>{'url': _encodedUrl});

        await tester.tap(find.byTooltip('下一首'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(state.current, same(next));
        Focus.of(tester.element(icon)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(calls, hasLength(2));
        expect(calls.last.method, 'openUrl');
        expect(calls.last.arguments, <String, Object>{
          'url': 'https://osu.ppy.sh/beatmapsets?q=Next+Artist+Second+%2B+Song',
        });
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('TV remote reaches and activates search with Select', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<MethodCall> calls = <MethodCall>[];
      _mockExternalUrl(tester, TargetPlatform.android, (MethodCall call) async {
        calls.add(call);
        return true;
      });
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue(<Track>[_encodedTrack]);
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            theme: buildLegacyTheme(),
            home: TvTraversalScope(
              child: Scaffold(
                body: DesktopNowPlaying(
                  state: state,
                  track: _encodedTrack,
                  artwork: const SizedBox.square(dimension: 120),
                  lyrics: const SizedBox.shrink(),
                  comments: const SizedBox.shrink(),
                  queue: const SizedBox.shrink(),
                  pane: DesktopNowPlayingPane.lyrics,
                  onPaneChanged: (_) {},
                  onBack: () {},
                  onSaveArtwork: () {},
                  onFullscreen: () {},
                  controlsVisible: true,
                  onActivity: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final Finder close = find.descendant(
        of: find.byKey(const ValueKey('desktop-close')),
        matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
      );
      final Finder search = find.descendant(
        of: find.byKey(const ValueKey('desktop-search-osu')),
        matching: find.byIcon(Icons.search_rounded),
      );
      final FocusNode closeFocus = Focus.of(tester.element(close));
      final FocusNode searchFocus = Focus.of(tester.element(search));
      closeFocus.requestFocus();
      await tester.pump();
      expect(closeFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(searchFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'openUrl');
      expect(calls.single.arguments, <String, Object>{'url': _encodedUrl});
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('is disabled when the track has no searchable metadata', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<MethodCall> calls = <MethodCall>[];
      _mockExternalUrl(tester, TargetPlatform.android, (MethodCall call) async {
        calls.add(call);
        return true;
      });
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_desktopPage(state, _track(artist: '未知歌手')));
      await tester.pump();

      final Finder button = find.byKey(const ValueKey('desktop-search-osu'));
      expect(button, findsOneWidget);
      expect(tester.widget<AccessibleIconButton>(button).onPressed, isNull);
      await tester.tap(button);
      await tester.pump();
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
