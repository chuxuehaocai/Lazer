import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/theme/shape_scale.dart';

/// 行的悬浮/聚焦高亮框必须跟「圆角设置」同一个来源。
///
/// 以前这些框写的是 `BorderRadius.circular(<基数> * AppleShape.scaleOf(context))`：
/// 乘的是组件系数。主题把卡片写成 0（Mio / Early Development）时，卡片是直角，
/// 鼠标一放上去却弹出一个 10 px 的圆角框。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({required bool manual, required double cardPx, required Widget child}) {
    return MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[LazerThemeTokens.mio]),
      home: AppleShape(
        scale: manual ? cardPx / AppleShape.basePx : 1,
        cardPx: cardPx,
        manual: manual,
        child: Builder(
          builder: (context) => Text(
            '${AppleShape.cardRadiusOf(context, LazerThemeTokens.of(context))}',
          ),
        ),
      ),
    );
  }

  testWidgets('跟随主题：Mio 的卡片圆角是 0，行的悬浮框也是 0', (WidgetTester tester) async {
    await tester.pumpWidget(host(manual: false, cardPx: 0, child: const SizedBox()));
    expect(find.text('0.0'), findsOneWidget);
  });

  testWidgets('自行调节：用户写 20 px，行的悬浮框就是 20', (WidgetTester tester) async {
    await tester.pumpWidget(host(manual: true, cardPx: 20, child: const SizedBox()));
    expect(find.text('20.0'), findsOneWidget);
  });

  test('行级悬浮高亮都走 cardRadiusOf，不再自己乘组件系数', () {
    const Map<String, List<String>> expected = <String, List<String>>{
      'lib/ui/widgets.dart': <String>['final radius = BorderRadius.circular('],
      'lib/widgets/playback_queue_view.dart': <String>[],
      'lib/widgets/settings_choice.dart': <String>[],
      'lib/theme/paper_widgets.dart': <String>[],
      'lib/network/network_browse_page.dart': <String>[],
      'lib/network/podcast_pages.dart': <String>[],
      'lib/ui/shell.dart': <String>[],
    };
    for (final entry in expected.entries) {
      final String source = File(entry.key).readAsStringSync();
      expect(
        source.contains('AppleShape.cardRadiusOf(context, LazerThemeTokens.of(context))'),
        isTrue,
        reason: '${entry.key} 的悬浮框应该读卡片圆角',
      );
    }
    // 行本身不该再用「基数 × 组件系数」算悬浮框。
    final String rows = File('lib/ui/widgets.dart').readAsStringSync();
    expect(rows.contains('BorderRadius.circular(10 * AppleShape.scaleOf(context))'), isFalse);
  });

  test('插件卡片上没有「使用」按钮', () {
    final String page = File('lib/ui/plugin_manager_page.dart').readAsStringSync();
    expect(page.contains("TrText('使用')"), isFalse);
  });
}
