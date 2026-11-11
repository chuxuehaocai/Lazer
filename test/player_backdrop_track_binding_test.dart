import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/shared_browse_background.dart';

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

const _first = Track(
  id: 'binding-first',
  title: 'Binding first',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);
const _second = Track(
  id: 'binding-second',
  title: 'Binding second',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'cached player and shared browse canvas receive the new track without reopening',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      // Both canvases are expected here; the browse default is now off.
      state.backgroundMode = AppBackgroundMode.nowPlayingDynamic;
      final navigation = BrowseNavigationObserver();
      addTearDown(navigation.dispose);
      state.playQueue([_first, _second]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          navigatorObservers: [navigation],
          builder: (context, child) => SharedBrowseBackground(
            state: state,
            navigation: navigation,
            child: child!,
          ),
          home: AppShell(state: state),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(AppPlayerBar),
          matching: find.text(_first.title),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(NowPlayingPage), findsOneWidget);
      final player = tester.element(find.byType(NowPlayingPage));
      final backdrop = tester.element(find.byType(AlbumBlurFlow));
      final browse = tester.element(find.byType(AppAlbumBackdrop));
      expect(
        tester.widget<AlbumBlurFlow>(find.byType(AlbumBlurFlow)).track,
        _first,
      );

      state.next();
      await tester.pump();

      expect(state.current, _second);
      expect(
        identical(tester.element(find.byType(NowPlayingPage)), player),
        isTrue,
      );
      expect(
        identical(tester.element(find.byType(AlbumBlurFlow)), backdrop),
        isTrue,
      );
      expect(
        identical(tester.element(find.byType(AppAlbumBackdrop)), browse),
        isTrue,
      );
      expect(
        tester.widget<AlbumBlurFlow>(find.byType(AlbumBlurFlow)).track,
        _second,
      );
      expect(
        tester.widget<AppAlbumBackdrop>(find.byType(AppAlbumBackdrop)).track,
        _second,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
