import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/local/local_music_page.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/detail_requests.dart';
import 'package:lazer_nextgen/navigation/system_back_gesture.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/home_pages.dart';
import 'package:lazer_nextgen/ui/library_page.dart';
import 'package:lazer_nextgen/ui/listening_statistics_page.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Track(
  id: 'shell-system-back',
  title: 'Back gesture fixture',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 100; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<AppState> _openLibrary(WidgetTester tester, {bool track = false}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state =
      AppState(
          catalog: _Catalog(),
          listeningStatistics: ListeningStatisticsController(
            read: () async => null,
            write: (_) async {},
          ),
        )
        ..uiMode = AppUiMode.mobile
        ..backgroundMode = AppBackgroundMode.off
        ..playerBackground = AppBackgroundMode.off;
  addTearDown(state.dispose);
  if (track) state.playQueue(const [_track]);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      home: AppShell(state: state, autoCheckUpdates: false),
    ),
  );
  await _settle(tester);
  await tester.tap(find.byTooltip('音乐库'));
  await _settle(tester);
  expect(find.byType(AppLibraryPage), findsOneWidget);
  return state;
}

Future<void> _android(
  WidgetTester tester,
  String method, [
  double? progress,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(
        method,
        progress == null
            ? null
            : <String, dynamic>{
                'touchOffset': <double>[5, 200],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (_) {},
  );
  await tester.pump();
}

double _playerSlide(WidgetTester tester) => tester
    .widget<SlideTransition>(
      find
          .ancestor(
            of: find.byType(NowPlayingPage),
            matching: find.byType(SlideTransition),
          )
          .first,
    )
    .position
    .value
    .dy;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'switching tabs from an album clears detail state at the Home root',
    (tester) async {
      await _openLibrary(tester);
      albumDetailRequest.value = const Album(
        id: '987654321',
        title: 'Navigation album',
        artist: 'Artist',
        year: '2026',
        note: '',
        coverSeed: 1,
      );
      await _settle(tester);
      expect(find.text('Navigation album'), findsWidgets);
      await tester.tap(find.byTooltip('主页'));
      await _settle(tester);
      expect(find.byType(AppHomePage), findsOneWidget);
      final back = tester.widget<SystemBackGesture>(
        find.byType(SystemBackGesture).first,
      );
      expect(
        back.canStart(),
        isFalse,
        reason: 'an album left by a tab change is no longer an open detail',
      );
      expect(
        tester.widget<PopScope<void>>(find.byType(PopScope<void>).first).canPop,
        isTrue,
      );
      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .7);
      expect(back.progress.value, isNull);
      await _android(tester, 'cancelBackGesture');
      await _settle(tester);
      expect(find.byType(AppHomePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'iOS shell cancels local history then returns to Library and Home in order',
    (tester) async {
      await _openLibrary(tester);
      await tester.tap(find.byKey(const ValueKey('open-local-music')));
      await _settle(tester);
      expect(find.byType(LocalMusicPage), findsOneWidget);

      var drag = await tester.startGesture(const Offset(5, 250));
      await drag.moveBy(const Offset(150, 0));
      await tester.pump();
      expect(find.byType(AppLibraryPage), findsOneWidget);
      await drag.cancel();
      await _settle(tester);
      expect(find.byType(LocalMusicPage), findsOneWidget);
      expect(find.byType(AppLibraryPage), findsNothing);

      drag = await tester.startGesture(const Offset(5, 250));
      await drag.moveBy(const Offset(290, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await drag.up();
      await _settle(tester);
      expect(find.byType(LocalMusicPage), findsNothing);
      expect(find.byType(AppLibraryPage), findsOneWidget);

      drag = await tester.startGesture(const Offset(5, 250));
      await drag.moveBy(const Offset(290, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await drag.up();
      await _settle(tester);
      expect(find.byType(AppHomePage), findsOneWidget);
      expect(find.byType(AppLibraryPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Android shell preserves cancelled history and gives a dialog priority',
    (tester) async {
      await _openLibrary(tester);
      await tester.tap(find.byKey(const ValueKey('open-local-music')));
      await _settle(tester);
      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .6);
      expect(find.byType(AppLibraryPage), findsOneWidget);
      await _android(tester, 'cancelBackGesture');
      await _settle(tester);
      expect(find.byType(LocalMusicPage), findsOneWidget);

      showDialog<void>(
        context: tester.element(find.byType(LocalMusicPage)),
        builder: (_) => const AlertDialog(title: Text('Covering dialog')),
      );
      await _settle(tester);
      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .8);
      await _android(tester, 'commitBackGesture');
      await _settle(tester);
      expect(find.text('Covering dialog'), findsNothing);
      expect(find.byType(LocalMusicPage), findsOneWidget);

      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .8);
      await _android(tester, 'commitBackGesture');
      await _settle(tester);
      expect(find.byType(LocalMusicPage), findsNothing);
      expect(find.byType(AppLibraryPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android player tracks back progress, restores on cancel and closes once',
    (tester) async {
      await _openLibrary(tester, track: true);
      await tester.tap(
        find.descendant(
          of: find.byType(AppPlayerBar),
          matching: find.text(_track.title),
        ),
      );
      await _settle(tester);
      expect(find.byType(NowPlayingPage), findsOneWidget);
      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .4);
      expect(_playerSlide(tester), closeTo(.4, .001));
      await _android(tester, 'cancelBackGesture');
      await _settle(tester);
      expect(_playerSlide(tester), 0);
      expect(find.byType(NowPlayingPage), findsOneWidget);
      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .8);
      await _android(tester, 'commitBackGesture');
      await _settle(tester);
      expect(find.byType(NowPlayingPage), findsNothing);
      expect(find.byType(AppLibraryPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'statistics route consumes Android back before the underlying shell',
    (tester) async {
      await _openLibrary(tester);
      await tester.tap(find.byKey(const ValueKey('open-listening-statistics')));
      await _settle(tester);
      expect(find.byType(AppListeningStatisticsPage), findsOneWidget);
      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .8);
      await _android(tester, 'commitBackGesture');
      await _settle(tester);
      expect(find.byType(AppListeningStatisticsPage), findsNothing);
      expect(find.byType(AppLibraryPage), findsOneWidget);
      expect(find.byType(AppHomePage), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
