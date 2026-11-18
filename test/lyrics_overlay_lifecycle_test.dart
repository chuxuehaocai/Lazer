import 'dart:async' show Completer;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/desktop_lyrics/lyrics_overlay.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_protocol.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_font_loader.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';

const _settings = LyricsOverlaySettings(
  lineCount: 3,
  fontSize: 22,
  fontWeight: 600,
  fontFamily: 'MiSans',
  fontPath: null,
  blurEnabled: true,
  blurIntensity: 1,
  animationSpeed: 1,
  lineSpacing: 16,
);

class _DelayedFontLoader extends OverlayFontLoader {
  final pending = Completer<void>();
  final finished = Completer<void>();

  @override
  Future<void> load(String family, String path) async {
    await pending.future;
    final bytes = await rootBundle.load('assets/fonts/RobotoMono-Regular.ttf');
    final loader = FontLoader(family)..addFont(Future.value(bytes));
    await loader.load();
    finished.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interactions = <Map<dynamic, dynamic>>[];
  setUp(() {
    interactions.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mixin.one/desktop_multi_window/channels'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'getBounds'
          ? {'x': 0.0, 'y': 0.0, 'width': 420.0, 'height': 320.0}
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(kDesktopLyricsChannel),
      (call) async {
        if (call.method == 'setInteractionRegions') {
          interactions.add(call.arguments as Map);
        }
        return true;
      },
    );
  });

  Future<OverlayBridge> mount(
    WidgetTester tester, {
    bool reduced = false,
    bool visible = true,
    OverlayFontLoader? fontLoader,
  }) async {
    final bridge = OverlayBridge();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [LazerThemeTokens.apple]),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(420, 320),
            disableAnimations: reduced,
          ),
          child: TickerMode(
            enabled: visible,
            child: LyricsOverlayApp(
              controller: WindowController.fromWindowId('fixture'),
              launch: const LyricsOverlayLaunch(
                mode: LyricsOverlayMode.floating,
                settings: _settings,
              ),
              channel: const WindowMethodChannel('fixture'),
              bridge: bridge,
              fontLoader: fontLoader,
            ),
          ),
        ),
      ),
    );
    return bridge;
  }

  Future<void> payload(OverlayBridge bridge, {bool words = false}) =>
      bridge.handler!(
        MethodCall(
          'state',
          LyricsOverlayPayload(
            title: 'Track',
            artist: 'Artist',
            notice: null,
            lines: List.generate(
              20,
              (i) => LyricLine(
                Duration(seconds: i * 30),
                'Line $i',
                words: words
                    ? [
                        LyricWord(
                          Duration(seconds: i * 30),
                          const Duration(seconds: 25),
                          'Line $i',
                        ),
                      ]
                    : const [],
              ),
            ),
            settings: _settings,
            position: Duration.zero,
            duration: const Duration(minutes: 10),
            playing: true,
          ).toMap(),
        ),
      );

  testWidgets('plain lyrics playing do not retain a vsync callback', (
    tester,
  ) async {
    final bridge = await mount(tester);
    await payload(bridge);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('word repaint preserves its tail then releases the ticker', (
    tester,
  ) async {
    final bridge = await mount(tester);
    await bridge.handler!(
      MethodCall(
        'state',
        const LyricsOverlayPayload(
          title: 'Track',
          artist: 'Artist',
          notice: null,
          lines: [
            LyricLine(
              Duration.zero,
              'First',
              words: [LyricWord(Duration.zero, Duration(seconds: 1), 'First')],
            ),
          ],
          settings: _settings,
          position: Duration(milliseconds: 1400),
          duration: Duration(seconds: 30),
          playing: true,
        ).toMap(),
      ),
    );
    await tester.pump();
    // The vocal duration has ended, but the last emphasized word still floats.
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await bridge.handler!(
      const MethodCall('position', {'position': 3000, 'playing': true}),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion snaps focus and avoids continuous word repaint', (
    tester,
  ) async {
    final bridge = await mount(tester, reduced: true);
    await payload(bridge, words: true);
    await bridge.handler!(
      const MethodCall('position', {'position': 90000, 'playing': true}),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden overlay does not leave a muted ticker running', (
    tester,
  ) async {
    final bridge = await mount(tester, visible: false);
    await payload(bridge, words: true);
    await tester.pump();
    // An active-but-muted ticker resumes immediately, and can still receive
    // position changes. Inspect the widget's diagnostic rather than merely
    // checking whether the framework happened to schedule a frame.
    final state = tester.state(find.byType(LyricsOverlayApp));
    final properties = DiagnosticPropertiesBuilder();
    state.debugFillProperties(properties);
    expect(
      properties.properties.where((p) => p.name == 'ticker').single.toString(),
      anyOf(contains('inactive'), contains('null')),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('locking clears native and Flutter lyric drag targets', (
    tester,
  ) async {
    final bridge = await mount(tester);
    await payload(bridge);
    await tester.pump();
    expect(find.byType(GestureDetector), findsWidgets);
    await bridge.handler!(
      MethodCall('settings', {..._settings.toMap(), 'locked': true}),
    );
    await tester.pump();
    expect(find.byType(GestureDetector), findsNothing);
    if (interactions.isNotEmpty) {
      expect(interactions.last['locked'], isTrue);
      expect(interactions.last['regions'], isEmpty);
    }
    await bridge.handler!(MethodCall('settings', _settings.toMap()));
    await tester.pump();
    expect(find.byType(GestureDetector), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'resize serializes native calls and coalesces to latest geometry',
    (tester) async {
      final bridge = await mount(tester);
      final firstPosition = Completer<Object?>();
      var positionRequests = 0;
      final sizes = <Map<dynamic, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            if (call.method == 'getBounds') {
              positionRequests++;
              if (positionRequests == 1) return firstPosition.future;
              return {'x': 0.0, 'y': 0.0, 'width': 420.0, 'height': 320.0};
            }
            if (call.method == 'setBounds' &&
                (call.arguments as Map).containsKey('height')) {
              sizes.add(call.arguments as Map);
            }
            return null;
          });
      await payload(bridge);
      await tester.pump();
      await bridge.handler!(
        MethodCall('settings', {
          ..._settings.toMap(),
          'fontSize': 40,
          'lineCount': 5,
        }),
      );
      await bridge.handler!(
        MethodCall('settings', {
          ..._settings.toMap(),
          'fontSize': 14,
          'lineCount': 1,
        }),
      );
      await tester.pump();
      expect(positionRequests, 1);
      firstPosition.complete({
        'x': 0.0,
        'y': 0.0,
        'width': 420.0,
        'height': 320.0,
      });
      await tester.pump();
      await tester.pump();
      expect(positionRequests, 2);
      expect(sizes, hasLength(2));
      expect(sizes.last['height'], 84); // one minimum 48 px slot + padding
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'updated lyric theme remeasures live overlay instead of launch theme',
    (tester) async {
      final bridge = await mount(tester);
      final sizes = <Map<dynamic, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            if (call.method == 'setBounds' &&
                (call.arguments as Map).containsKey('height')) {
              sizes.add(call.arguments as Map);
            }
            return call.method == 'getBounds'
                ? {'x': 0.0, 'y': 0.0, 'width': 420.0, 'height': 320.0}
                : null;
          });
      await payload(bridge);
      await tester.pump();
      final previous = (sizes.last['height'] as num).toDouble();
      await bridge.handler!(
        MethodCall('settings', {
          ..._settings.toMap(),
          'theme': LazerThemeTokens.apple
              .copyWith(lyricFontScale: 2, lyricLineHeight: 2)
              .toJson(),
        }),
      );
      await tester.pump();
      expect((sizes.last['height'] as num).toDouble(), greaterThan(previous));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late font registration remeasures window before painting loaded glyphs',
    (tester) async {
      final fonts = _DelayedFontLoader();
      final bridge = await mount(tester, fontLoader: fonts);
      final widths = <double>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            if (call.method == 'setBounds' &&
                (call.arguments as Map)['width'] != null) {
              widths.add(((call.arguments as Map)['width'] as num).toDouble());
            }
            return call.method == 'getBounds'
                ? {'x': 0.0, 'y': 0.0, 'width': 420.0, 'height': 320.0}
                : null;
          });
      await bridge.handler!(
        MethodCall(
          'state',
          LyricsOverlayPayload(
            title: '',
            artist: '',
            notice: null,
            lines: const [LyricLine(Duration.zero, 'MMMMMMMMMMMMMMMMMMMM')],
            settings: LyricsOverlaySettings.fromMap({
              ..._settings.toMap(),
              'fontFamily': 'OverlayDelayedMono',
              'fontPath': 'fixture.ttf',
            }),
            position: Duration.zero,
            duration: const Duration(minutes: 1),
            playing: false,
          ).toMap(),
        ),
      );
      await tester.pump();
      final fallbackWidth = widths.last;
      fonts.pending.complete();
      await tester.runAsync(() => fonts.finished.future);
      await tester.pump();
      await tester.pump();
      expect(widths.last, lessThan(fallbackWidth));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'font completion after overlay disposal performs no window work',
    (tester) async {
      final fonts = _DelayedFontLoader();
      final bridge = await mount(tester, fontLoader: fonts);
      await bridge.handler!(
        MethodCall('settings', {
          ..._settings.toMap(),
          'fontFamily': 'OverlayDisposedMono',
          'fontPath': 'fixture.ttf',
        }),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            _,
          ) async {
            calls++;
            return null;
          });
      fonts.pending.complete();
      await tester.runAsync(() => fonts.finished.future);
      await tester.pump();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
      expect(bridge.handler, isNull);
    },
  );
}
