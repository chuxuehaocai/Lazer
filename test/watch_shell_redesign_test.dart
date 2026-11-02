import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/watch/watch_shell.dart';
import 'package:lazer_nextgen/watch/watch_shape_list.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryLibrary extends LocalLibrary {
  @override
  Future<void> load() async {}
}

class _WatchState extends AppState {
  _WatchState({required bool round, required String cover, super.catalog})
    : fixtures = [
        for (var i = 0; i < 1200; i++)
          Track(
            id: 'watch-$i',
            title: i == 0 ? '晴天的漫游' : '歌曲 $i',
            artist: '旅行中的音乐家',
            album: '沿途风景',
            duration: const Duration(minutes: 3),
            coverSeed: i,
            coverUrl: cover,
          ),
      ],
      super(
        deviceIsWatch: true,
        deviceIsRoundWatch: round,
        localLibrary: _MemoryLibrary(),
      );

  final List<Track> fixtures;
  final ValueNotifier<int> _ticks = ValueNotifier(0);
  bool isPlaying = false;
  int index = 0;
  double fraction = .38;
  final List<double> seeks = [];
  List<Track>? played;
  int? playedIndex;
  String? searchQuery;
  String? phone, captcha;
  Completer<AuthOutcome>? pendingCode;

  @override
  Future<AuthOutcome> sendSmsCode(String phone) =>
      pendingCode?.future ?? Future.value(const AuthOutcome(true));

  @override
  Track get current => fixtures[index];
  @override
  List<Track> get queue => fixtures;
  @override
  bool get playing => isPlaying;
  @override
  Listenable get ticks => _ticks;
  @override
  double get progress => fraction;
  @override
  Duration get position => Duration(milliseconds: (180000 * fraction).round());
  @override
  Duration get precisePosition => position;
  @override
  void togglePlay() {
    isPlaying = !isPlaying;
    notifyListeners();
  }

  @override
  void next() {
    index++;
    notifyListeners();
  }

  @override
  void previous() {
    if (index > 0) index--;
    notifyListeners();
  }

  @override
  void seek(double fraction) {
    seeks.add(fraction);
    this.fraction = fraction;
    _ticks.value++;
  }

  @override
  void playQueue(List<Track> tracks, {int startIndex = 0}) {
    played = tracks;
    playedIndex = startIndex;
    index = fixtures.indexOf(tracks[startIndex]);
    notifyListeners();
  }

  @override
  Future<SearchResults> search(String query) async {
    searchQuery = query;
    return SearchResults(tracks: [fixtures.last]);
  }

  @override
  Future<AuthOutcome> signInWithPhoneCaptcha(
    String phone,
    String captcha,
  ) async {
    this.phone = phone;
    this.captcha = captcha;
    return const AuthOutcome(true);
  }

  void tick() {
    fraction += .001;
    _ticks.value++;
  }

  @override
  void dispose() {
    super.dispose();
    _ticks.dispose();
  }
}

class _DelayedCatalog extends Catalog {
  final playlist = Completer<List<Track>>();
  @override
  Future<List<Track>> playlistTracks(String id) => playlist.future;
}

void _insideEllipse(Rect rect, Size size) {
  final rx = size.width / 2 - 2;
  final ry = size.height / 2 - 2;
  for (final point in [
    rect.topLeft,
    rect.topRight,
    rect.bottomLeft,
    rect.bottomRight,
  ]) {
    final x = (point.dx - size.width / 2) / rx;
    final y = (point.dy - size.height / 2) / ry;
    expect(
      x * x + y * y,
      lessThanOrEqualTo(1.001),
      reason: '$rect leaves the round display at $point',
    );
  }
}

Future<void> _screenshot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (!const bool.fromEnvironment('SAVE_WATCH_PROBES')) return;
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('diag/watch-redesign').create(recursive: true);
    await File(
      'diag/watch-redesign/$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late String cover;
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf')))
        .load();
    temporary = await Directory.systemTemp.createTemp('watch-redesign-');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const bounds = Rect.fromLTWH(0, 0, 256, 256);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 0),
          const Offset(256, 256),
          [const Color(0xFFE89961), const Color(0xFFB54658)],
        ),
    );
    canvas.drawCircle(
      const Offset(150, 130),
      85,
      Paint()..color = const Color(0xFF2D3A40),
    );
    canvas.drawCircle(
      const Offset(150, 130),
      52,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFB6C0B8),
    );
    canvas.drawCircle(
      const Offset(150, 130),
      20,
      Paint()..color = const Color(0xFFEFCB9A),
    );
    final label = TextPainter(
      text: const TextSpan(
        text: 'SUNDAY\nWANDER',
        style: TextStyle(
          fontFamily: 'MiSans',
          fontSize: 25,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, const Offset(17, 16));
    label.dispose();
    final picture = recorder.endRecording();
    final image = await picture.toImage(256, 256);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${temporary.path}/cover.png');
    await file.writeAsBytes(png!.buffer.asUint8List());
    cover = file.uri.toString();
    image.dispose();
    picture.dispose();
  });
  tearDownAll(() async => temporary.delete(recursive: true));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<GlobalKey> mount(
    WidgetTester tester,
    _WatchState state,
    Size size,
    bool round, {
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: Colors.black,
            child: round
                ? ClipOval(
                    child: WatchShell(state: state, round: round),
                  )
                : WatchShell(state: state, round: round),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    if (find.byType(Image).evaluate().isNotEmpty) {
      await tester.runAsync(
        () => precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          key.currentContext!,
        ),
      );
    }
    await tester.pumpAndSettle();
    return key;
  }

  for (final round in [false, true]) {
    for (final size in [
      const Size(160, 160),
      const Size(192, 192),
      if (round) const Size(240, 240) else const Size(240, 280),
    ]) {
      testWidgets(
        '${round ? 'round' : 'square'} $size player controls fit and respond without scrolling',
        (tester) async {
          final state = _WatchState(round: round, cover: cover);
          addTearDown(state.dispose);
          final key = await mount(tester, state, size, round);
          expect(find.byType(Image), findsOneWidget);
          expect(
            tester.getSize(find.byType(Image)),
            Size.square(
              (round ? .27 : .32) *
                  (size.width < size.height ? size.width : size.height),
            ),
          );
          for (final tooltip in [
            '音乐',
            '设置',
            '播放',
            '上一首',
            '下一首',
            '播放队列',
            '歌词与状态',
          ]) {
            final target = find.byTooltip(tooltip);
            expect(target.hitTestable(), findsOneWidget);
            if (round) _insideEllipse(tester.getRect(target), size);
          }
          final playRect = tester.getRect(find.byTooltip('播放'));
          expect(
            playRect.overlaps(tester.getRect(find.byTooltip('上一首'))),
            isFalse,
          );
          expect(
            playRect.overlaps(tester.getRect(find.byTooltip('下一首'))),
            isFalse,
          );
          await _screenshot(
            tester,
            key,
            '${round ? 'round' : 'square'}-${size.width.toInt()}x${size.height.toInt()}-player',
          );
          await tester.tap(find.byTooltip('播放'));
          await tester.pump();
          expect(state.playing, isTrue);
          await tester.tap(find.byTooltip('下一首'));
          await tester.pump();
          expect(state.index, 1);
          await tester.tap(find.byTooltip('上一首'));
          await tester.pump();
          expect(state.index, 0);
          await tester.tap(find.byTooltip('音乐'));
          await tester.pump();
          expect(find.text('搜索音乐'), findsOneWidget);
          if (round) _insideEllipse(tester.getRect(find.byTooltip('返回')), size);
          await _screenshot(
            tester,
            key,
            '${round ? 'round' : 'square'}-${size.width.toInt()}x${size.height.toInt()}-library',
          );
          await tester.tap(find.byTooltip('返回'));
          await tester.pump();
          expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('round dark display keeps contrast and compact control bounds', (
    tester,
  ) async {
    final state = _WatchState(round: true, cover: cover);
    addTearDown(state.dispose);
    final key = await mount(
      tester,
      state,
      const Size(160, 160),
      true,
      brightness: Brightness.dark,
    );
    for (final label in ['音乐', '设置', '播放', '上一首', '下一首']) {
      expect(find.byTooltip(label).hitTestable(), findsOneWidget);
      _insideEllipse(
        tester.getRect(find.byTooltip(label)),
        const Size(160, 160),
      );
    }
    await _screenshot(tester, key, 'round-160x160-dark-player');
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue builds only nearby rows and opens any selected song', (
    tester,
  ) async {
    final state = _WatchState(round: true, cover: cover);
    addTearDown(state.dispose);
    await mount(tester, state, const Size(192, 192), true);
    await tester.tap(find.byTooltip('播放队列'));
    await tester.pump();
    int rows() => find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'watch-track-',
              ),
        )
        .evaluate()
        .length;
    expect(rows(), lessThan(20));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('watch-track-watch-1199')),
      findsOneWidget,
    );
    expect(rows(), lessThan(20));
    await tester.tap(find.byKey(const ValueKey('watch-track-watch-1199')));
    await tester.pump();
    expect(state.playedIndex, 1199);
    expect(find.byKey(const ValueKey('watch-player')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'transport ticks update the progress leaf without rebuilding the watch player',
    (tester) async {
      final state = _WatchState(round: true, cover: cover);
      addTearDown(state.dispose);
      await mount(tester, state, const Size(192, 192), true);
      var playerBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget.key == const ValueKey('watch-player')) {
          playerBuilds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      final before = tester
          .widget<AccessibleSlider>(find.byType(AccessibleSlider))
          .value;
      for (var i = 0; i < 10; i++) {
        state.tick();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester.widget<AccessibleSlider>(find.byType(AccessibleSlider)).value,
        greaterThan(before),
      );
      expect(playerBuilds, 0);
      final slider = tester.widget<AccessibleSlider>(
        find.byType(AccessibleSlider),
      );
      slider.onChangeStart!(.4);
      slider.onChanged!(.5);
      slider.onChanged!(.6);
      expect(state.seeks, isEmpty);
      slider.onChangeEnd!(.6);
      await tester.pump();
      expect(state.seeks, [.6]);
    },
  );

  testWidgets(
    'search and current lyrics remain reachable from the round player',
    (tester) async {
      final state = _WatchState(round: true, cover: cover)
        ..lyrics = const [LyricLine(Duration.zero, '把每一天写成歌')];
      addTearDown(state.dispose);
      await mount(tester, state, const Size(192, 192), true);
      await tester.tap(find.byTooltip('歌词与状态'));
      await tester.pump();
      expect(find.text('把每一天写成歌'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      await tester.tap(find.byTooltip('音乐'));
      await tester.pump();
      await tester.tap(find.text('搜索音乐'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('watch-search-query')),
        '晴天',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(state.searchQuery, '晴天');
      expect(find.text('歌曲 1199'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final round in [true, false]) {
    testWidgets(
      '${round ? 'round' : 'square'} large text stays scrollable and keeps its return control',
      (tester) async {
        final state = _WatchState(round: round, cover: cover);
        addTearDown(state.dispose);
        final key = await mount(
          tester,
          state,
          const Size(192, 192),
          round,
          textScale: 1.7,
        );
        expect(find.byType(WatchShapeList), findsOneWidget);
        expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byTooltip('播放').hitTestable(),
          30,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byTooltip('播放'));
        await tester.pump();
        expect(state.playing, isTrue);
        await _screenshot(
          tester,
          key,
          '${round ? 'round' : 'square'}-large-text',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${round ? 'round' : 'square'} near-fullscreen keyboard never creates negative constraints',
      (tester) async {
        for (final size in [const Size(160, 160), const Size(192, 192)]) {
          final state = _WatchState(round: round, cover: cover);
          await mount(tester, state, size, round);
          await tester.tap(find.byTooltip('设置'));
          await tester.pump();
          await tester.enterText(
            find.byKey(const ValueKey('watch-login-phone')),
            '13800000000',
          );
          for (final bottom in [110.0, 170.0, 240.0]) {
            tester.view.viewInsets = FakeViewPadding(bottom: bottom);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: '$size IME=$bottom');
          }
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
          expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
          await tester.tap(find.byTooltip('返回'));
          await tester.pump();
          expect(find.byKey(const ValueKey('watch-player')), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          state.dispose();
        }
      },
    );

    testWidgets(
      '${round ? 'round' : 'square'} input stays above an ordinary Android keyboard',
      (tester) async {
        final state = _WatchState(round: round, cover: cover);
        addTearDown(state.dispose);
        await mount(tester, state, const Size(192, 192), round);
        await tester.tap(find.byTooltip('设置'));
        await tester.pump();
        final phone = find.byKey(const ValueKey('watch-login-phone'));
        await tester.enterText(phone, '13800000000');
        tester.view.viewInsets = const FakeViewPadding(bottom: 100);
        await tester.pumpAndSettle();
        expect(tester.getRect(phone).bottom, lessThanOrEqualTo(92));
        expect(tester.getRect(phone).top, greaterThanOrEqualTo(0));
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        final code = find.byKey(const ValueKey('watch-login-captcha'));
        await tester.scrollUntilVisible(
          code,
          30,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(code, '123456');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(state.phone, '13800000000');
        expect(state.captcha, '123456');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'late playlist and account responses cannot replace a newer watch navigation',
    (tester) async {
      final catalog = _DelayedCatalog();
      final state = _WatchState(round: false, cover: cover, catalog: catalog)
        ..collections = const UserCollections(
          created: [
            Playlist(id: 'delayed', name: '晚到的歌单', trackIds: [], coverSeed: 1),
          ],
        );
      addTearDown(state.dispose);
      await mount(tester, state, const Size(192, 192), false);
      await tester.tap(find.byTooltip('音乐'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('晚到的歌单').hitTestable(),
        30,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('晚到的歌单'));
      await tester.pump();
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      await tester.tap(find.byTooltip('音乐'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('本地音乐 · 0').hitTestable(),
        -30,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('本地音乐 · 0'));
      await tester.pump();
      catalog.playlist.complete([state.fixtures.last]);
      await tester.pump();
      expect(find.text('本地音乐'), findsOneWidget);
      expect(find.text('暂无歌曲'), findsOneWidget);
      expect(find.text('歌曲 1199'), findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      state.pendingCode = Completer<AuthOutcome>();
      await tester.tap(find.byTooltip('设置'));
      await tester.pump();
      await tester.tap(find.text('发送验证码'));
      await tester.pump();
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      state.pendingCode!.complete(const AuthOutcome(true));
      await tester.pump();
      expect(find.byKey(const ValueKey('watch-player')), findsOneWidget);
      expect(find.text('验证码已发送'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
