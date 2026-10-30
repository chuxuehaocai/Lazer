import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/media_shortcuts.dart';
import 'package:lazer_nextgen/widgets/media_shortcut_listener.dart';
import 'package:lazer_nextgen/widgets/shortcut_recorder_dialog.dart';

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');

  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[];
}

Widget _app(Widget home) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: home,
);

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = true,
}) async {
  if (control) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.sendKeyEvent(key);
  if (control) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('bindings encode, decode and detect conflicts', () {
    final Map<MediaShortcutAction, MediaShortcutBinding?> defaults =
        MediaShortcutSettings.defaults();
    const MediaShortcutBinding ctrlUp = MediaShortcutBinding(
      LogicalKeyboardKey.arrowUp,
      control: true,
    );
    const MediaShortcutBinding custom = MediaShortcutBinding(
      LogicalKeyboardKey.keyK,
      control: true,
      alt: true,
      shift: true,
      meta: true,
    );

    expect(
      mediaShortcutActionFor(defaults, ctrlUp),
      MediaShortcutAction.volumeUp,
    );
    expect(
      mediaShortcutConflict(
        defaults,
        action: MediaShortcutAction.playPause,
        binding: ctrlUp,
      ),
      MediaShortcutAction.volumeUp,
    );
    expect(
      mediaShortcutConflict(
        defaults,
        action: MediaShortcutAction.volumeUp,
        binding: ctrlUp,
      ),
      isNull,
    );
    expect(MediaShortcutBinding.decode(custom.encode()), custom);
    expect(MediaShortcutBinding.decode('nonsense'), isNull);
    expect(MediaShortcutBinding.decode(''), isNull);

    final Map<MediaShortcutAction, MediaShortcutBinding?> decoded =
        MediaShortcutSettings.decode('{"playPause":""}');
    expect(decoded[MediaShortcutAction.playPause], isNull);
    expect(
      decoded[MediaShortcutAction.nextTrack],
      defaults[MediaShortcutAction.nextTrack],
    );
    expect(MediaShortcutSettings.decode('{broken'), defaults);
    expect(MediaShortcutSettings.decode(null), defaults);

    final String encoded = MediaShortcutSettings.encode(
      <MediaShortcutAction, MediaShortcutBinding?>{
        ...defaults,
        MediaShortcutAction.playPause: custom,
        MediaShortcutAction.mute: null,
      },
    );
    final Map<MediaShortcutAction, MediaShortcutBinding?> roundTrip =
        MediaShortcutSettings.decode(encoded);
    expect(roundTrip[MediaShortcutAction.playPause], custom);
    expect(roundTrip[MediaShortcutAction.mute], isNull);
  });

  test('AppState persists, restores and resets media shortcuts', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    const MediaShortcutBinding custom = MediaShortcutBinding(
      LogicalKeyboardKey.keyK,
      control: true,
      shift: true,
    );

    await state.setMediaShortcut(MediaShortcutAction.playPause, custom);
    await state.setMediaShortcut(MediaShortcutAction.nextTrack, null);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString('lazer_media_shortcuts');
    expect(stored, isNotNull);
    expect(stored, contains('"playPause"'));
    expect(stored, contains('"nextTrack":""'));

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.mediaShortcutFor(MediaShortcutAction.playPause), custom);
    expect(restarted.mediaShortcutFor(MediaShortcutAction.nextTrack), isNull);

    await restarted.resetMediaShortcuts();
    for (final MediaShortcutAction action in MediaShortcutAction.values) {
      expect(
        restarted.mediaShortcutFor(action),
        kDefaultMediaShortcuts[action],
      );
    }
    expect(prefs.getString('lazer_media_shortcuts'), isNull);
  });

  testWidgets('the global listener controls volume and skips typing', (
    tester,
  ) async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setVolume(0.5);
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaShortcutListener(
          state: state,
          child: Material(child: TextField(controller: controller)),
        ),
      ),
    );
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(state.volume, closeTo(0.55, 1e-9));

    await _press(tester, LogicalKeyboardKey.keyM);
    expect(state.volume, 0);
    await _press(tester, LogicalKeyboardKey.keyM);
    expect(state.volume, closeTo(0.55, 1e-9));

    // A recorder dialog suspends playback shortcuts.
    MediaShortcutRecorder.begin();
    try {
      await _press(tester, LogicalKeyboardKey.arrowUp);
    } finally {
      MediaShortcutRecorder.end();
    }
    expect(state.volume, closeTo(0.55, 1e-9));

    // Typing in a text field must never change the volume.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(state.volume, closeTo(0.55, 1e-9));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Settings records and saves a custom shortcut', (tester) async {
    tester.view.physicalSize = const Size(1280, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _app(
        Scaffold(
          body: AnimatedBuilder(
            animation: state,
            builder: (BuildContext context, _) =>
                LegacySettingsPage(state: state),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('open-shortcut-settings'));
    await tester.scrollUntilVisible(entry, 200);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final Finder row = find.byKey(const ValueKey('media-shortcut-playPause'));
    await tester.scrollUntilVisible(
      row,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('设置快捷键'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Ctrl + K'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shortcut-save')));
    await tester.pumpAndSettle();
    final MediaShortcutBinding? saved = state.mediaShortcutFor(
      MediaShortcutAction.playPause,
    );
    expect(saved?.key, LogicalKeyboardKey.keyK);
    expect(saved?.control, isTrue);
    expect(saved?.shift, isFalse);
    expect(find.text('Ctrl + K'), findsOneWidget);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lazer_media_shortcuts'), contains('"playPause"'));
  });

  testWidgets('the recorder rejects a combination owned by another action', (
    tester,
  ) async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showShortcutRecorderDialog(
                context,
                action: MediaShortcutAction.playPause,
                current: state.mediaShortcutFor(MediaShortcutAction.playPause),
                conflict: (MediaShortcutBinding binding) =>
                    mediaShortcutConflict(
                      state.mediaShortcuts,
                      action: MediaShortcutAction.playPause,
                      binding: binding,
                    ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('已用于「增大音量」'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('shortcut-save')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('shortcut-record-again')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('shortcut-save')))
          .onPressed,
      isNotNull,
    );
  });
}
