import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';

Track _track(String title) => Track(
  id: 'layout-fixture',
  title: title,
  artist: 'Test artist',
  album: 'Test album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

Widget _page(AppState state, Track track) => MaterialApp(
  theme: buildLegacyTheme(),
  home: Scaffold(
    body: DesktopNowPlaying(
      state: state,
      track: track,
      artwork: const ColoredBox(
        key: ValueKey('test-artwork'),
        color: Colors.blue,
      ),
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

  testWidgets('desktop song actions stay aligned to the artwork edge', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog());
    addTearDown(state.dispose);

    for (final size in <Size>[
      const Size(1280, 800),
      const Size(1280, 650),
    ]) {
      tester.view.physicalSize = size;
      for (final title in <String>[
        'Short title',
        'A long song title that wraps and continues well beyond two lines',
      ]) {
        await tester.pumpWidget(_page(state, _track(title)));
        await tester.pump();

        final Rect artwork = tester.getRect(
          find.byKey(const ValueKey('test-artwork')),
        );
        final Rect listen = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is AccessibleIconButton && widget.tooltip == '一起听',
          ),
        );
        final Rect like = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is AccessibleIconButton && widget.tooltip == '登录后收藏',
          ),
        );
        final Rect titleRect = tester.getRect(find.text(title));

        expect(
          like.right,
          closeTo(artwork.right, .01),
          reason: 'actions should line up with the actual artwork at $size',
        );
        expect(listen.right, lessThanOrEqualTo(like.left));
        expect(titleRect.right, lessThanOrEqualTo(listen.left));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
