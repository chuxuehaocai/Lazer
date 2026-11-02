import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const _preferenceKey = 'lazer_independent_playback';
const _home = HomeFeed(
  recommended: <Playlist>[],
  featuredTracks: <Track>[],
  quick: <Track>[],
  playlists: <Playlist>[],
  albums: <Album>[],
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog({this.homeRequest}) : super(gateway: _Gateway());

  final Completer<HomeFeed?>? homeRequest;
  final homeRequested = Completer<void>();

  @override
  HomeFeed get home => _home;

  @override
  Future<HomeFeed?> loadHome({int? userId}) {
    if (!homeRequested.isCompleted) homeRequested.complete();
    return homeRequest?.future ?? Future<HomeFeed?>.value(home);
  }

  @override
  Future<UserCollections> userCollections(int uid) async =>
      UserCollections.empty;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

void _expectPlaybackGroup(WidgetTester tester) {
  final playback = find.text('播放');
  final independent = find.text('独立播放');
  final interaction = find.text('交互');
  expect(playback, findsOneWidget);
  expect(independent, findsOneWidget);
  expect(interaction, findsOneWidget);
  expect(
    tester.getTopLeft(playback).dy,
    lessThan(tester.getTopLeft(independent).dy),
  );
  expect(
    tester.getTopLeft(independent).dy,
    lessThan(tester.getTopLeft(interaction).dy),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('independent playback defaults off and persists both choices', () async {
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.independentPlayback, isFalse);
    await state.bootstrap();
    expect(state.independentPlayback, isFalse);

    final prefs = await SharedPreferences.getInstance();
    for (final enabled in <bool>[true, false]) {
      await state.setIndependentPlayback(enabled);
      expect(state.independentPlayback, enabled);
      expect(prefs.getBool(_preferenceKey), enabled);

      final restored = AppState(catalog: _Catalog());
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.independentPlayback, enabled);
    }
  });

  for (final enabled in <bool>[true, false]) {
    test(
      'bootstrap restores $enabled before the home feed completes',
      () async {
        final homeRequest = Completer<HomeFeed?>();
        final catalog = _Catalog(homeRequest: homeRequest);
        final state = AppState(catalog: catalog);
        addTearDown(state.dispose);
        await state.setIndependentPlayback(!enabled);
        SharedPreferences.setMockInitialValues({_preferenceKey: enabled});
        expect(state.independentPlayback, !enabled);
        final notifications = <bool>[];
        state.addListener(() => notifications.add(state.independentPlayback));

        final bootstrap = state.bootstrap();
        await catalog.homeRequested.future;
        try {
          expect(homeRequest.isCompleted, isFalse);
          expect(state.independentPlayback, enabled);
          expect(notifications, contains(enabled));
        } finally {
          homeRequest.complete(_home);
          await bootstrap;
        }
        expect(state.independentPlayback, enabled);
      },
    );
  }

  testWidgets(
    'App settings toggle independent playback in the playback group',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: state,
          builder: (context, _) => MaterialApp(
            theme: buildAppleTheme(),
            home: Scaffold(body: AppSettingsPage(state: state)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final label = find.text('独立播放');
      await tester.scrollUntilVisible(label, 200);
      // The lazily built heading can be above the row after alignment.
      // Bring it into view before comparing the group's positions.
      await tester.scrollUntilVisible(find.text('播放'), -100);
      await tester.pumpAndSettle();
      _expectPlaybackGroup(tester);
      final row = find.ancestor(of: label, matching: find.byType(Row)).first;
      final toggle = find.descendant(of: row, matching: find.byType(Switch));
      expect(toggle, findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      final prefs = await SharedPreferences.getInstance();

      for (final enabled in <bool>[true, false]) {
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(state.independentPlayback, enabled);
        expect(tester.widget<Switch>(toggle).value, enabled);
        expect(prefs.getBool(_preferenceKey), enabled);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
