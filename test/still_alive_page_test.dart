import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_audio.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_page.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_score.dart';
import 'package:lazer_nextgen/ui/settings_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Playback extends ChangeNotifier implements StillAlivePlayback {
  @override
  bool ready = false;
  @override
  bool playing = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(microseconds: 176404875);
  @override
  String? error;
  int pauses = 0, closes = 0;
  final volumes = <double>[];
  @override
  Future<void> setVolume(double value) async => volumes.add(value);
  Completer<void>? loading;
  @override
  Future<void> load() async {
    await loading?.future;
    ready = error == null;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    pauses++;
    notifyListeners();
  }

  @override
  Future<void> restart() async {
    position = Duration.zero;
    await play();
  }

  void move(Duration value) {
    position = value;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    playing = false;
    closes++;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

StillAlivePage _page(WidgetTester tester, _Playback audio) {
  final start = tester.binding.clock.now();
  return StillAlivePage(
    playback: audio,
    clock: () => tester.binding.clock.now().difference(start),
  );
}

Future<void> _startMusic(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(StillAliveScore.original.musicStart);
  await tester.pump();
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_STILL_ALIVE_PROBES')) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('diag/still-alive/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final mono = File('C:/Windows/Fonts/consola.ttf');
    if (mono.existsSync()) {
      for (final family in ['Consolas', 'monospace', 'Menlo']) {
        await (FontLoader(family)..addFont(
              mono.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            ))
            .load();
      }
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final (size, dpr) in [
    (const Size(390, 844), 1.0),
    (const Size(844, 390), 1.0),
    (const Size(1280, 720), 1.0),
    (const Size(240, 280), 1.0),
    (const Size(390, 844), 2.5),
  ]) {
    testWidgets(
      'terminal fits $size at device scale $dpr and follows audio position',
      (tester) async {
        tester.view.physicalSize = size * dpr;
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.reset);
        final audio = _Playback();
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(key: key, child: _page(tester, audio)),
          ),
        );
        await tester.pump();
        expect(
          audio.playing,
          isFalse,
          reason: 'The report introduction precedes the recording',
        );
        await _startMusic(tester);
        expect(audio.playing, isTrue);
        audio.move(const Duration(seconds: 30));
        await tester.pump();
        final frame = StillAliveScore.original.frameAt(
          StillAliveScore.original.musicStart + const Duration(seconds: 30),
        );
        expect(find.textContaining(frame.text), findsOneWidget);
        expect(find.text(frame.asciiArt), findsOneWidget);
        expect(
          find.byKey(
            ValueKey(
              size.width > size.height * 1.15
                  ? 'still-alive-landscape'
                  : 'still-alive-portrait',
            ),
          ),
          findsOneWidget,
        );
        for (final name in [
          'still-alive-report',
          'still-alive-art',
          'still-alive-credits',
          'still-alive-close',
          'still-alive-play',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(name)));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        await _shot(
          tester,
          key,
          '${size.width.toInt()}x${size.height.toInt()}-$dpr',
        );
        await tester.tap(find.byKey(const ValueKey('still-alive-play')));
        await tester.pump();
        expect(audio.playing, isFalse);
        await tester.tap(find.byKey(const ValueKey('still-alive-restart')));
        await tester.pump();
        expect(audio.playing, isFalse);
        await _startMusic(tester);
        expect(audio.position, Duration.zero);
        expect(audio.playing, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(audio.closes, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('orientation and DPI changes preserve the score and audio', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final audio = _Playback();
    await tester.pumpWidget(MaterialApp(home: _page(tester, audio)));
    await _startMusic(tester);
    audio.move(const Duration(seconds: 91));
    await tester.pump();
    final position = audio.position;
    tester.view.physicalSize = const Size(1688, 780);
    tester.view.devicePixelRatio = 2;
    await tester.pump();
    expect(find.byKey(const ValueKey('still-alive-landscape')), findsOneWidget);
    expect(audio.position, position);
    expect(audio.playing, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'the prelude and music continue in the background and visuals catch up',
    (tester) async {
      final audio = _Playback()..loading = Completer<void>();
      await tester.pumpWidget(MaterialApp(home: _page(tester, audio)));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      audio.loading!.complete();
      await tester.pump();
      expect(audio.playing, isFalse);
      expect(audio.pauses, 0);
      await _startMusic(tester);
      expect(audio.playing, isTrue);
      audio.move(const Duration(seconds: 90));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(audio.playing, isTrue);
      final frame = StillAliveScore.original.frameAt(
        StillAliveScore.original.musicStart + const Duration(seconds: 90),
      );
      expect(find.textContaining(frame.text), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(audio.playing, isTrue);
      expect(audio.pauses, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('visual polling follows reduced motion and route TickerMode', (
    tester,
  ) async {
    final audio = _Playback();
    final reducedMotion = ValueNotifier(false);
    final routeVisible = ValueNotifier(true);
    addTearDown(reducedMotion.dispose);
    addTearDown(routeVisible.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: reducedMotion,
          builder: (context, reduced, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: ValueListenableBuilder<bool>(
              valueListenable: routeVisible,
              child: StillAlivePage(playback: audio),
              builder: (context, visible, child) =>
                  TickerMode(enabled: visible, child: child!),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final dynamic pageState = tester.state(find.byType(StillAlivePage));
    expect(pageState.debugPollInterval, const Duration(milliseconds: 33));
    expect(pageState.debugIsPolling, isTrue);

    reducedMotion.value = true;
    await tester.pump();
    expect(pageState.debugPollInterval, const Duration(seconds: 1));
    expect(pageState.debugIsPolling, isTrue);

    routeVisible.value = false;
    await tester.pump();
    expect(pageState.debugIsPolling, isFalse);
    routeVisible.value = true;
    await tester.pump();
    expect(pageState.debugIsPolling, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'music waits for 7.1 seconds and personnel uses its separate 9.3 second start',
    (tester) async {
      final audio = _Playback();
      await tester.pumpWidget(MaterialApp(home: _page(tester, audio)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 7099));
      expect(audio.playing, isFalse);
      expect(find.textContaining('This was a triumph.'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(audio.playing, isTrue);
      audio.move(const Duration(milliseconds: 2199));
      await tester.pump();
      final panel = find.byKey(const ValueKey('still-alive-credits'));
      expect(
        find.descendant(of: panel, matching: find.text('>L')),
        findsNothing,
      );
      audio.move(const Duration(milliseconds: 2200));
      await tester.pump();
      expect(
        find.descendant(of: panel, matching: find.text('>L')),
        findsOneWidget,
      );
      audio.move(audio.duration!);
      await tester.pump();
      expect(
        find.descendant(
          of: panel,
          matching: find.textContaining('THANK YOU FOR PARTICIPATING'),
        ),
        findsOneWidget,
      );
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, Colors.black);
      for (final box in tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(StillAlivePage),
          matching: find.byType(DecoratedBox),
        ),
      )) {
        if (box.decoration case BoxDecoration(color: final color?)) {
          expect(color, Colors.black);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'audio failure remains visible until an explicit silent demonstration',
    (tester) async {
      final audio = _Playback()..error = 'No output device';
      await tester.pumpWidget(
        MaterialApp(home: StillAlivePage(playback: audio)),
      );
      await tester.pump();
      expect(find.text('音频暂时无法播放'), findsOneWidget);
      expect(audio.playing, isFalse);
      await tester.pump(const Duration(seconds: 3));
      expect(audio.position, Duration.zero);
      await tester.tap(find.text('静音演示'));
      await tester.pump();
      expect(find.text('静音演示'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(audio.closes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'credits finish with only replay and repeated replays reset the full introduction',
    (tester) async {
      final audio = _Playback();
      await tester.pumpWidget(MaterialApp(home: _page(tester, audio)));
      await _startMusic(tester);
      for (var cycle = 0; cycle < 3; cycle++) {
        audio.playing = false;
        audio.move(audio.duration!);
        await tester.pump();
        expect(find.byKey(const ValueKey('still-alive-play')), findsNothing);
        expect(
          find.byKey(const ValueKey('still-alive-restart')),
          findsOneWidget,
        );
        expect(find.text('THANK YOU FOR PARTICIPATING'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('still-alive-restart')));
        await tester.pump();
        expect(audio.playing, isFalse);
        expect(find.byKey(const ValueKey('still-alive-play')), findsOneWidget);
        expect(find.textContaining('0:00 /'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 7099));
        expect(audio.playing, isFalse);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(audio.playing, isTrue);
        expect(audio.position, Duration.zero);
        audio.move(const Duration(seconds: 1));
        await tester.pump();
        final frame = StillAliveScore.original.frameAt(
          StillAliveScore.original.musicStart + const Duration(seconds: 1),
        );
        expect(find.textContaining(frame.text), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the egg follows main volume before sound, while playing, and in the background',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await state.setVolume(.25);
      final audio = _Playback();
      final start = tester.binding.clock.now();
      await tester.pumpWidget(
        MaterialApp(
          home: StillAlivePage(
            playback: audio,
            appState: state,
            clock: () => tester.binding.clock.now().difference(start),
          ),
        ),
      );
      await tester.pump();
      expect(audio.volumes.last, .25);
      expect(audio.playing, isFalse);
      await _startMusic(tester);
      await state.setVolume(.7);
      expect(audio.volumes.last, .7);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await state.setVolume(0);
      expect(audio.volumes.last, 0);
      expect(audio.playing, isTrue);
      await state.setVolume(.4);
      expect(audio.volumes.last, .4);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      final reports = audio.volumes.length;
      await state.setVolume(.9);
      expect(audio.volumes.length, reports);
      expect(tester.takeException(), isNull);
    },
  );

  for (final number in [true, false]) {
    testWidgets(
      'seven ${number ? 'version-number' : 'version-row'} taps open the egg while debug controls stay visible',
      (tester) async {
        final state = AppState();
        addTearDown(state.dispose);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.ryanheise.just_audio.methods'),
          (_) async => <String, Object?>{},
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AppSettingsPage(state: state)),
          ),
        );
        await tester.pumpAndSettle();
        final version = find.byKey(const ValueKey('still-alive-version'));
        await tester.scrollUntilVisible(
          version,
          600,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 40,
        );
        final target = number ? version : find.text('Lazer');
        for (var tap = 0; tap < 6; tap++) {
          await tester.tap(target);
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.byType(StillAlivePage), findsNothing);
        // Sparse taps time out instead of unexpectedly opening the credits.
        await tester.pump(const Duration(seconds: 5));
        await tester.tap(target);
        await tester.pump();
        expect(find.byType(StillAlivePage), findsNothing);
        for (var tap = 0; tap < 6; tap++) {
          await tester.tap(target);
          await tester.pump(const Duration(milliseconds: 40));
        }
        await tester.pumpAndSettle();
        expect(find.byType(StillAlivePage), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('still-alive-close')));
        await tester.pumpAndSettle();
        expect(find.byType(StillAlivePage), findsNothing);
        await tester.scrollUntilVisible(
          find.text('调试'),
          -300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('调试'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
