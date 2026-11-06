import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/library_page.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The browse page is the *background* of the player's back gesture: the
/// player slides down over it. It has no destination to return to, so the
/// retained switcher must leave it exactly where it is.
const _track = Track(
  id: 'player-back-browse',
  title: 'Browse fixture',
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

Future<void> _openPlayer(WidgetTester tester) async {
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
  state.playQueue(const [_track]);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      home: AppShell(state: state, autoCheckUpdates: false),
    ),
  );
  await _settle(tester);
  await tester.tap(find.text('音乐库').last);
  await _settle(tester);
  expect(find.byType(AppLibraryPage), findsOneWidget);
  await tester.tap(
    find.descendant(
      of: find.byType(AppPlayerBar),
      matching: find.text(_track.title),
    ),
  );
  await _settle(tester);
  expect(find.byType(NowPlayingPage), findsOneWidget);
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

/// Every page wrapper the switcher is currently painting. None of them may be
/// translated while the player's own gesture is what is in flight.
List<FractionalTranslation> _browseWrappers(WidgetTester tester) => tester
    .widgetList<FractionalTranslation>(
      find.descendant(
        of: find.byType(RetainedContentSwitcher),
        matching: find.byType(FractionalTranslation),
      ),
    )
    .toList();

double _browseOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(AppLibraryPage),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'a player back gesture leaves the browse page underneath it alone',
    (tester) async {
      await _openPlayer(tester);
      await _android(tester, 'startBackGesture', 0);
      await _android(tester, 'updateBackGestureProgress', .9);

      expect(
        _playerSlide(tester),
        closeTo(.9, .001),
        reason: 'the player has to follow the gesture',
      );
      expect(
        _browseWrappers(tester).map((w) => w.translation),
        everyElement(Offset.zero),
        reason:
            'the browse pages are the backdrop of this gesture, not pages '
            'being dismissed, so none of them may travel',
      );
      expect(
        _browseOpacity(tester),
        1,
        reason: 'the browse page must stay fully painted behind the player',
      );

      await _android(tester, 'cancelBackGesture');
      await _settle(tester);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
