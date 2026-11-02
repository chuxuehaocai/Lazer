import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/lyric_image_dialog.dart';

const _lines = [
  LyricLine(Duration.zero, '窓の向こうに 朝が来る', translation: '窗外，清晨正悄悄到来'),
  LyricLine(Duration(seconds: 3), '昨日の夢を そっとほどいて', translation: '轻轻解开昨日的梦'),
  LyricLine(Duration(seconds: 6), 'まだ知らない 今日を歌おう', translation: '唱起尚未相识的今天'),
];

Future<void> _artworkReady(WidgetTester tester, Track track) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (find
      .byKey(const ValueKey('lyric-image-loading'))
      .evaluate()
      .isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Artwork did not finish loading.');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
  expect(
    tester.widget<LyricImageCard>(find.byType(LyricImageCard)).track.id,
    track.id,
  );
}

Future<void> _snapshot(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PROBES')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('diag').create(recursive: true);
    await File('diag/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixtureDirectory;
  late File artwork;
  late Track track;
  setUpAll(() async {
    await (FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    fixtureDirectory = await Directory.systemTemp.createTemp('lazer_dialog_');
    artwork = File('${fixtureDirectory.path}/artwork.png');
    // Deterministic cover fixture; preview and export must use the same image.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 360, 360),
      Paint()..color = const Color(0xffd7afa4),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 280, 360, 80),
      Paint()..color = const Color(0xff635445),
    );
    final arch = Path()
      ..moveTo(65, 300)
      ..lineTo(65, 170)
      ..cubicTo(65, 30, 295, 30, 295, 170)
      ..lineTo(295, 300)
      ..close();
    canvas.drawPath(arch, Paint()..color = const Color(0xffeee8d7));
    canvas.drawCircle(
      const Offset(180, 165),
      58,
      Paint()..color = const Color(0xffc67557),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(360, 360);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await artwork.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    track = Track(
      id: 'preview',
      title: '夜明けの手紙',
      artist: 'Lazer Sessions',
      album: '朝の余白',
      duration: const Duration(minutes: 3),
      coverSeed: 1,
      coverUrl: artwork.uri.toString(),
    );
  });
  tearDownAll(() async {
    await artwork.delete();
    await fixtureDirectory.delete();
  });

  testWidgets(
    'dialog preserves its source theme and animates opening, artwork and closing',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: Theme(
              data: buildAppleTheme(brightness: Brightness.dark),
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showLyricImageDialog(
                    context,
                    track: track,
                    lines: _lines,
                  ),
                  child: const Text('打开预览'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开预览'));
      await tester.pump();
      final dialog = find.byType(LyricImageDialog);
      final scale = find
          .ancestor(of: dialog, matching: find.byType(ScaleTransition))
          .first;
      expect(tester.widget<ScaleTransition>(scale).scale.value, lessThan(1));
      expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);
      expect(find.byKey(const ValueKey('lyric-image-loading')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<ScaleTransition>(scale).scale.value,
        inExclusiveRange(.96, 1),
      );
      await _artworkReady(tester, track);
      expect(find.byKey(const ValueKey('lyric-image-loading')), findsNothing);
      expect(find.byType(LyricImageCard), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<ScaleTransition>(scale).scale.value,
        inExclusiveRange(.96, 1),
      );
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final configuration in [
    (const Size(320, 568), Brightness.dark, 1.0),
    (const Size(390, 844), Brightness.dark, 1.0),
    (const Size(640, 360), Brightness.light, 1.0),
    (const Size(1280, 800), Brightness.light, 1.0),
    (const Size(320, 568), Brightness.light, 2.0),
  ]) {
    testWidgets('preview keeps its controls visible at $configuration', (
      tester,
    ) async {
      final (size, brightness, textScale) = configuration;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: buildAppleTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: LyricImageDialog(track: track, lines: _lines),
            ),
          ),
        ),
      );
      await _artworkReady(tester, track);
      final save = tester.getRect(find.byType(FilledButton));
      final back = tester.getRect(find.text('返回选择'));
      expect(save.top, greaterThanOrEqualTo(0));
      expect(save.bottom, lessThanOrEqualTo(size.height));
      expect(back.bottom, lessThanOrEqualTo(size.height));
      expect(find.byType(LyricImageCard), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _snapshot(
        tester,
        key,
        'lyric_dialog_${brightness.name}_${size.width.toInt()}_${size.height.toInt()}_${textScale.toInt()}x',
      );
    });
  }

  testWidgets(
    'save feedback handles a failed save, cancellation and successful retry without changing the PNG',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      final destination = File('${fixtureDirectory.path}/selected.png');
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        if (await destination.exists()) await destination.delete();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(brightness: Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showLyricImageDialog(context, track: track, lines: _lines),
                child: const Text('打开预览'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开预览'));
      await tester.pump();
      await _artworkReady(tester, track);

      Future<Completer<String?>> startSave() async {
        final called = Completer<void>();
        final choice = Completer<String?>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            expect(call.method, 'getSavePath');
            expect(
              (call.arguments as Map)['suggestedName'],
              '${track.title} - lyrics.png',
            );
            called.complete();
            return choice.future;
          },
        );
        await tester.tap(find.text('保存图片'));
        await tester.pump();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!called.isCompleted) {
          if (DateTime.now().isAfter(deadline)) {
            fail('The save dialog did not open.');
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(find.text('正在保存…'), findsOneWidget);
        return choice;
      }

      final failing = await startSave();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(LyricImageDialog), findsOneWidget);
      failing.completeError(PlatformException(code: 'unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请检查相册权限或稍后重试。'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );

      final cancelled = await startSave();
      cancelled.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请检查相册权限或稍后重试。'), findsNothing);
      expect(find.text('歌词图片已保存'), findsNothing);

      final successful = await startSave();
      successful.complete(destination.path);
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var fileComplete = false;
      while (!fileComplete) {
        if (DateTime.now().isAfter(deadline)) fail('The image was not saved.');
        fileComplete = (await tester.runAsync(() async {
          try {
            final bytes = await destination.readAsBytes();
            return bytes.length > 12 &&
                String.fromCharCodes(
                      bytes.sublist(bytes.length - 8, bytes.length - 4),
                    ) ==
                    'IEND';
          } on FileSystemException {
            return false;
          }
        }))!;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          await destination.readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1080);
        final rgba = await frame.image.toByteData();
        int pixel(double x, double y) =>
            rgba!.getUint32(((y * frame.image.width + x) * 4).round());
        final int firstFlowColor = pixel(
          frame.image.width * .08,
          frame.image.height * .12,
        );
        final int secondFlowColor = pixel(
          frame.image.width * .92,
          frame.image.height * .88,
        );
        expect(
          firstFlowColor,
          isNot(secondFlowColor),
          reason: 'the exported card includes its flowing Material backdrop',
        );
        frame.image.dispose();
        codec.dispose();
      });
      await tester.pumpAndSettle();
      expect(find.text('歌词图片已保存'), findsOneWidget);
      expect(find.text('再次保存'), findsOneWidget);
      await tester.tap(find.text('返回选择'));
      await tester.pumpAndSettle();
      expect(find.byType(LyricImageDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isAndroid || Platform.isIOS,
  );
}
