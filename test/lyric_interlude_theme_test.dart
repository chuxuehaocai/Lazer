import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/interlude.dart';
import 'package:lazer_nextgen/lyrics/line_content.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';

/// 视口里的间奏三点必须和歌词正文同色。
///
/// 之前三点写死 `Colors.white`：羊皮纸（浅色）主题下歌词是黑的、三点是白的，
/// 在纸上等于隐形。这条测试把「同一屏里两个元素的墨色一致」钉住。
class _Fixture extends AppState {
  _Fixture() {
    lyrics = <LyricLine>[
      const LyricLine(Duration.zero, '第一行'),
      const LyricLine(Duration(seconds: 3), '', end: Duration(seconds: 12)),
      const LyricLine(Duration(seconds: 12), '第三行'),
    ];
  }

  final lane = ChangeNotifier();

  @override
  Listenable get all => lane;

  @override
  Track get current => const Track(
    id: 'interlude',
    title: 'Fixture',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(seconds: 30),
    coverSeed: 1,
  );

  @override
  bool get playing => false;

  @override
  Duration get position => const Duration(seconds: 5);

  @override
  Duration get precisePosition => const Duration(seconds: 5);

  @override
  void dispose() {
    lane.dispose();
    super.dispose();
  }
}

/// 皮肤可以给一个浅色画布：`LazerThemeTokens.apple` 是深色预设，测不到这个问题。
LazerThemeTokens _paperSkin() => LazerThemeTokens.apple.copyWith(
  backgroundPlayMode: 'off',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('羊皮纸主题：间奏三点跟着歌词用同一个墨色', (tester) async {
    tester.view.physicalSize = const Size(640, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _Fixture();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.light, ui: _paperSkin()),
        home: Scaffold(body: LyricViewport(state: state)),
      ),
    );
    await tester.pumpAndSettle();

    final dots = tester.widget<LyricInterludeDots>(
      find.byType(LyricInterludeDots),
    );
    // 三点不再自带颜色：它按当前画布自己解（lyricCanvasInk）。
    expect(
      dots.ink,
      isNull,
      reason: '调用方不该把颜色烘进这行 Widget —— 视口会缓存整行，切主题后就旧了',
    );
    final Color lightInk = lyricCanvasInk(
      tester.element(find.byType(LyricInterludeDots)),
    );
    expect(
      lightInk,
      isNot(Colors.white),
      reason: '浅色主题下三点不能还是白点',
    );
    expect(
      lightInk.computeLuminance(),
      lessThan(.5),
      reason: '纸上的墨必须是深色的',
    );

    // 换到深色画布，墨色必须跟着变回浅色 —— 说明它读的是主题，不是常量。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        home: Scaffold(body: LyricViewport(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    final Color darkInk = lyricCanvasInk(
      tester.element(find.byType(LyricInterludeDots)),
    );
    expect(
      darkInk.computeLuminance(),
      greaterThan(.5),
      reason: '暗幕上三点要是浅色',
    );
    expect(tester.takeException(), isNull);
  });
}
