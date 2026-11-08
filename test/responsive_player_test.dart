import 'support/music_gateway.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/interaction/app_haptics.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/interaction_feedback.dart';
import 'package:lazer_nextgen/widgets/window_title_area.dart';

const _track = Track(
  id: '1939575649',
  title: 'まにまに',
  artist: 'r-906 / 初音ミク',
  album: 'まにまに',
  duration: Duration(minutes: 4),
  coverSeed: 1,
  coverUrl: 'https://example.com/cover.jpg',
  translatedTitle: '测试译名',
);
const _playlist = Playlist(
  id: '12',
  name: '测试歌单详情',
  trackIds: [],
  coverSeed: 1,
  trackCount: 1,
);

class _Catalog extends Catalog {
  _Catalog({super.gateway});
  @override
  Future<UserCollections> userCollections(int uid) async =>
      const UserCollections(
        liked: Playlist(
          id: '99',
          name: '喜欢的音乐',
          trackIds: [],
          coverSeed: 1,
          trackCount: 1,
        ),
        created: [_playlist],
      );
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: [_playlist],
    featured: Album(
      id: '9',
      title: 'I Look To You',
      artist: 'Whitney Houston',
      year: '',
      coverSeed: 1,
      note: '',
    ),
    featuredTracks: [],
    quick: [],
    playlists: [_playlist],
    albums: [],
  );
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00.00]第一句歌词\n[00:02.00]第二句歌词\n[00:04.00]第三句歌词\n[00:06.00]第四句歌词',
    tlyric:
        '[00:00.00]第一句翻译\n[00:02.00]第二句翻译\n[00:04.00]第三句翻译\n[00:06.00]第四句翻译',
  );
  @override
  Future<List<Track>> playlistTracks(String id) async => [_track];
}

class _AuthGateway extends TestMusicGateway {
  _AuthGateway({this.qrCompletes = false});

  /// Whether the fake QR poll reports a confirmed scan. Widget tests that only
  /// want the sign-in card to stay open leave it at "waiting" — the panel
  /// polls immediately now, so a 803 would close the dialog on the first frame.
  final bool qrCompletes;

  static const status = FixtureLoginStatus(
    profile: FixtureProfile(
      userId: 7,
      nickname: '测试账户',
      vipType: 11,
      avatarUrl: 'https://example.com/avatar.jpg',
    ),
  );
  @override
  Future<FixtureLoginStatus> fixtureLoginWithCookie(String cookie) async {
    sessionCookie = cookie;
    return status;
  }

  @override
  Future<FixtureLoginStatus> fixtureLoginStatus() async => status;

  @override
  Future<String> createQrKey() async => 'fixture-key';
  @override
  Future<FixtureQrCheck> checkQrCode(
    String key, {
    String secureCaptcha = '',
  }) async {
    if (!qrCompletes) return const FixtureQrCheck(code: 801);
    sessionCookie = 'MUSIC_U=fixture';
    return const FixtureQrCheck(code: 803, cookie: 'MUSIC_U=fixture');
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PROBES')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('diag/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final font = FontLoader('MiSans')
      ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/MiSans-Medium.ttf'))
      ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'window title area owns the title and the caption buttons outside a '
    'Material scaffold',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: buildAppleTheme(),
            builder: (context, child) => Column(
              children: [
                const WindowTitleArea(),
                Expanded(child: child!),
              ],
            ),
            home: const Scaffold(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.text('Lazer'),
          matching: find.byType(RichText),
        ),
      );
      expect(rich.text.style?.decoration, TextDecoration.none);
      expect(rich.text.style?.fontWeight, FontWeight.w400);
      expect(
        rich.text.style?.color,
        buildAppleTheme().colorScheme.onSurfaceVariant,
      );
      // A fixed strip of chrome above the pages, holding the title and all
      // three caption buttons on one row, flush with the trailing edge.
      final Rect area = tester.getRect(find.byType(WindowTitleArea));
      expect(area.height, kWindowTitleAreaHeight);
      for (final String id in <String>[
        'window-title-minimize',
        'window-title-fullscreen',
        'window-title-close',
      ]) {
        final Finder button = find.byKey(ValueKey<String>(id));
        expect(button, findsOneWidget);
        expect(
          tester.getSize(button),
          const Size(kWindowCaptionButtonWidth, kWindowTitleAreaHeight),
        );
      }
      final Finder close = find.byKey(
        const ValueKey<String>('window-title-close'),
      );
      expect(tester.getTopRight(close).dx, area.right);
      // The cap keeps a screen-reader name even though the bar sits above the
      // Navigator, outside the route's semantics tree.
      expect(
        find.descendant(
          of: close,
          matching: find.byWidgetPredicate(
            (Widget widget) =>
                widget is Semantics && widget.properties.label == '关闭窗口',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, key, 'ui_title_latest');
    },
  );

  test('confirmed QR adopts and persists a verified session', () async {
    final state = AppState(
      catalog: _Catalog(gateway: _AuthGateway(qrCompletes: true)),
    );
    addTearDown(state.dispose);
    final url = await state.beginQrLogin();
    expect(await state.pollQrLogin(url!), 803);
    expect(state.signedIn, true);
    expect(state.user.method, AuthMethod.qrcode);
  });

  test(
    'restored queue loads current lyrics without starting playback',
    () async {
      SharedPreferences.setMockInitialValues({
        'lazer_playback_queue_v1': jsonEncode({
          'index': 0,
          'tracks': [
            {
              'id': _track.id,
              'title': _track.title,
              'artist': _track.artist,
              'album': _track.album,
              'durationMs': 240000,
              'coverUrl': _track.coverUrl,
            },
          ],
        }),
      });
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.bootstrap();
      for (int attempt = 0; attempt < 100 && state.lyricsLoading; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(state.current?.id, _track.id);
      expect(state.playing, false);
      expect(state.lyricsLoading, false);
      expect(state.lyrics, hasLength(4));
    },
  );

  testWidgets('control feedback respects the persisted off setting', (
    tester,
  ) async {
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    int pulses = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      AppHaptics.channel,
      (call) async {
        if (call.method == 'impact') pulses++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AppHaptics.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      InteractionFeedback(
        state: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: feedbackAction(context, () {}),
                child: const Text('触摸反馈'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触摸反馈'));
    await tester.pump();
    expect(pulses, 1);
    await state.setHapticsEnabled(false);
    await tester.tap(find.text('触摸反馈'));
    await tester.pump();
    expect(pulses, 1);
    expect(
      (await SharedPreferences.getInstance()).getBool('lazer_haptics'),
      false,
    );
    await state.setLyricControlsSeconds(4);
    expect(
      (await SharedPreferences.getInstance()).getDouble(
        'lazer_lyric_controls_seconds',
      ),
      4,
    );
    await state.setLyricBlurEnabled(false);
    await state.setScrollRetention(.98);
    await state.setLyricResumeSeconds(3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lazer_lyric_blur'), false);
    expect(prefs.getDouble('lazer_scroll_retention'), .98);
    expect(prefs.getDouble('lazer_lyric_resume_seconds'), 3);
  });

  testWidgets('an iOS control pulses the native impact channel', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AppHaptics.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          AppHaptics.channel,
          null,
        ),
      );
      DateTime clock = DateTime(2026);
      final haptics = AppHaptics(now: () => clock);
      await haptics.pulse(enabled: true, intensity: .6);
      clock = clock.add(const Duration(milliseconds: 200));
      await haptics.pulse(enabled: true, intensity: .6, detent: true);
      clock = clock.add(const Duration(milliseconds: 200));
      await haptics.pulse(enabled: true, intensity: .6, boundary: true);

      expect(calls.map((MethodCall call) => call.method), <String>[
        'impact',
        'impact',
        'impact',
      ]);
      expect(
        calls.map(
          (MethodCall call) =>
              (call.arguments as Map<Object?, Object?>)['kind'],
        ),
        <String>['tap', 'detent', 'boundary'],
      );
      // Detents are softened so a drag cannot drown out the tap feedback.
      expect((calls.first.arguments as Map<Object?, Object?>)['intensity'], .6);
      expect(
        (calls[1].arguments as Map<Object?, Object?>)['intensity'] as double,
        closeTo(.33, .0001),
      );
      expect((calls.last.arguments as Map<Object?, Object?>)['intensity'], .6);

      // The off switch and a zero strength never reach the platform.
      await haptics.pulse(enabled: false, intensity: .6);
      await haptics.pulse(enabled: true, intensity: 0);
      expect(calls, hasLength(3));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
