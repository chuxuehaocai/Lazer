import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

const _track = Track(
  id: 'fixture',
  title: 'Raspberry',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

class _ChromeState extends AppState {
  _ChromeState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    titleBarStyle = DesktopTitleBarStyle.inline;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  bool get autoUpdateCheckDue => false;

  @override
  Track get current => _track;

  @override
  bool get playing => false;

  @override
  HomeFeed get home => const HomeFeed(
    featuredTracks: [],
    quick: [],
    daily: [],
    playlists: [],
    recommended: [],
    albums: [],
  );
}

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Both title bar styles paint the player's action row inside a capsule — the
  // frame floats it Inline, the page draws it under a classic strip — so a hover
  // has to stay clean in either presentation.
  for (final DesktopTitleBarStyle style in DesktopTitleBarStyle.values) {
    testWidgets('player capsule buttons survive pointer hovers: ${style.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1294, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method.startsWith('is') ? false : null,
      );
      await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('en')),
      );
      final state = _ChromeState()..titleBarStyle = style;
      await state.setIndependentPlayback(true);
      await tester.pumpWidget(
        LazerApp(
          state: state,
          audio: _UnusedAudio(),
          media: SystemMediaController(state),
          windowFrameEnabled: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Raspberry').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(2, 2));
      addTearDown(mouse.removePointer);

      // These buttons are painted through the frame's root overlay so they sit
      // inside the capsule. A Tooltip there would host a second overlay portal
      // under the first one's deferred layout box, which trips the theater's
      // depth invariant, so hover must stay clean for every one of them.
      for (final String key in <String>[
        'window-title-minimize',
        'window-title-close',
        'desktop-close',
        'desktop-search-osu',
        'desktop-add-to-playlist',
        'desktop-download',
        'desktop-play-pause',
      ]) {
        final Finder target = find.byKey(ValueKey<String>(key));
        expect(target, findsOneWidget, reason: key);
        await mouse.moveTo(tester.getCenter(target.first));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        expect(tester.takeException(), isNull, reason: 'hover over $key');
        await mouse.moveTo(const Offset(2, 400));
        await tester.pump(const Duration(milliseconds: 300));
      }
      // The capsule's own buttons keep their caption labels in semantics.
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('desktop-close')),
          matching: find.byType(Semantics),
        ),
        findsWidgets,
      );
    });
  }
}
