import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/library_page.dart';
import 'package:lazer_nextgen/ui/listening_statistics_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sun = Track(
  id: 'sun',
  title: '清晨的风',
  artist: 'Morning Light',
  album: '沿途',
  duration: Duration(minutes: 12),
  coverSeed: 1,
);
const _city = Track(
  id: 'city',
  title: '城市夜航',
  artist: 'Night Travelers',
  album: '夜色',
  duration: Duration(minutes: 9),
  coverSeed: 2,
);
const _paper = Track(
  id: 'paper',
  title: '纸飞机',
  artist: 'Summer Notes',
  album: '夏日回声',
  duration: Duration(minutes: 4),
  coverSeed: 3,
);

Future<ListeningStatisticsController> _fixture({bool empty = false}) async {
  var clock = DateTime(2026, 11, 6, 23, 59);
  final controller = ListeningStatisticsController(
    now: () => clock,
    read: () async => null,
    write: (_) async {},
  );
  await controller.ready;
  if (empty) return controller;

  void listen(Track track, DateTime at, int minutes, {bool skipped = false}) {
    clock = at;
    controller.begin(track, Duration.zero);
    final heard = Duration(minutes: minutes);
    clock = clock.add(heard);
    controller.sample(heard);
    if (skipped) controller.recordSkipTo(_sun);
    controller.end();
  }

  listen(_city, DateTime(2026, 10, 10, 21), 8);
  listen(_sun, DateTime(2026, 11, 2, 8), 12);
  listen(_city, DateTime(2026, 11, 5, 12), 7);
  listen(_sun, DateTime(2026, 11, 6, 7), 12);
  for (var play = 0; play < 4; play++) {
    listen(_paper, DateTime(2026, 11, 6, 18, play * 4), 3, skipped: true);
  }
  for (var play = 0; play < 3; play++) {
    listen(_city, DateTime(2026, 11, 6, 21, play * 10), 9);
  }
  listen(_paper, DateTime(2026, 11, 6, 23), 3, skipped: true);
  clock = DateTime(2026, 11, 6, 23, 59);
  await controller.flush();
  return controller;
}

Future<void> _mount(
  WidgetTester tester,
  ListeningStatisticsController controller, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Locale locale = const Locale.fromSubtags(
    languageCode: 'zh',
    scriptCode: 'Hans',
  ),
  Key? captureKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: brightness),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      builder: (context, child) => RepaintBoundary(
        key: captureKey,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
      home: AppListeningStatisticsPage(statistics: controller),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, Key key, String path) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('MiSans');
    for (final weight in <String>['Regular', 'Medium', 'Semibold', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/fonts/MiSans-$weight.ttf'));
    }
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final locale in AppLocalizations.supportedLocales) {
      await AppLocalizations.delegate.load(locale);
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('empty history is explicit and every range remains available', (
    tester,
  ) async {
    final controller = await _fixture(empty: true);
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    expect(
      find.byKey(const ValueKey('listening-statistics-empty')),
      findsOneWidget,
    );
    expect(find.text('0 秒'), findsOneWidget);
    expect(find.text('一天中的音乐时光'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('listening-range-allTime')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('listening-statistics-empty')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'range totals, hourly inspection and skip ranking use recorded plays',
    (tester) async {
      final controller = await _fixture();
      addTearDown(controller.dispose);
      final semantics = tester.ensureSemantics();
      try {
        const capture = ValueKey('statistics-preview');
        await _mount(tester, controller, captureKey: capture);
        expect(find.bySemanticsLabel('听歌时长, 1 小时 13 分钟'), findsOneWidget);
        expect(find.bySemanticsLabel('播放次数, 11'), findsOneWidget);
        expect(find.bySemanticsLabel('主动切歌, 5'), findsOneWidget);
        expect(find.text('21:00–22:00 · 27 分钟'), findsOneWidget);
        await _capture(
          tester,
          capture,
          'build/listening_statistics_preview.png',
        );

        await tester.tap(find.byKey(const ValueKey('listening-range-today')));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('听歌时长, 54 分钟'), findsOneWidget);
        expect(find.bySemanticsLabel('播放次数, 9'), findsOneWidget);

        final chart = find.byKey(const ValueKey('listening-hour-chart'));
        await tester.ensureVisible(chart);
        await tester.pumpAndSettle();
        final chartNode = tester.getSemantics(chart);
        tester
            .renderObject(chart)
            .owner!
            .semanticsOwner!
            .performAction(chartNode.id, ui.SemanticsAction.increase);
        await tester.pump();
        expect(find.text('22:00–23:00 · 0 秒'), findsOneWidget);

        await tester.scrollUntilVisible(find.text('切歌 5 次 · 15 分钟'), 260);
        expect(find.text('纸飞机'), findsWidgets);
        expect(find.text('切歌 5 次 · 15 分钟'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('large English text fits a narrow phone through the full page', (
    tester,
  ) async {
    final controller = await _fixture();
    addTearDown(controller.dispose);
    await _mount(
      tester,
      controller,
      size: const Size(320, 850),
      textScale: 1.8,
      locale: const Locale('en'),
    );
    expect(find.text('Listening statistics'), findsOneWidget);
    for (final range in ListeningRange.values) {
      expect(
        find.byKey(ValueKey('listening-range-${range.name}')),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('About these records'), 350);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop dark layout keeps both rankings beside each other', (
    tester,
  ) async {
    final controller = await _fixture();
    addTearDown(controller.dispose);
    const capture = ValueKey('statistics-desktop-preview');
    await _mount(
      tester,
      controller,
      size: const Size(1280, 1080),
      brightness: Brightness.dark,
      captureKey: capture,
    );
    final skips = tester.getTopLeft(find.text('最常切走的歌'));
    final plays = tester.getTopLeft(find.text('最常播放的歌'));
    expect(skips.dy, plays.dy);
    expect(plays.dx, greaterThan(skips.dx));
    expect(tester.takeException(), isNull);
    await _capture(
      tester,
      capture,
      'build/listening_statistics_desktop_preview.png',
    );
  });

  testWidgets(
    'the library entry opens statistics and system back returns to the library',
    (tester) async {
      final controller = await _fixture(empty: true);
      final state = AppState(listeningStatistics: controller);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: AppLibraryPage(
              state: state,
              onOpenPlaylist: (_) {},
              onOpenLocalMusic: () {},
              onOpenSavedAlbums: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-listening-statistics')));
      await tester.pumpAndSettle();
      expect(find.byType(AppListeningStatisticsPage), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppListeningStatisticsPage), findsNothing);
      expect(
        find.byKey(const ValueKey('open-listening-statistics')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
