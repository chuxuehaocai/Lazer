import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/diagnostics/export_logs.dart';
import 'package:lazer_nextgen/diagnostics/frame_stats.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ui.FrameTiming> _frames({
  required double fps,
  double buildMs = 4,
  double rasterMs = 4,
}) => List.generate(120, (index) {
  final start = (index * 1000000 / fps).round();
  final build = (buildMs * 1000).round();
  final raster = (rasterMs * 1000).round();
  return ui.FrameTiming(
    vsyncStart: start,
    buildStart: start,
    buildFinish: start + build,
    rasterStart: start + build,
    rasterFinish: start + build + raster,
    rasterFinishWallTime: start + build + raster,
  );
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final refreshRate in [30.0, 60.0, 90.0, 120.0, 144.0, 240.0]) {
    test('$refreshRate Hz has its own frame budget and healthy cadence', () {
      final stats = FrameStats.forTesting(
        timings: _frames(fps: refreshRate, buildMs: 2, rasterMs: 3),
        refreshRate: refreshRate,
      );
      addTearDown(stats.dispose);
      expect(stats.fps, closeTo(refreshRate, .02));
      expect(stats.budgetMs, closeTo(1000 / refreshRate, .001));
      expect(
        frameBudgetHealth(
          live: stats.live,
          refreshRate: stats.refreshRate,
          lowFps: stats.lowFps,
          pipelineMs: stats.pipelineMs,
        ),
        FrameBudgetHealth.withinBudget,
      );
      expect(frameBudgetVerdict(stats), startsWith('低帧符合显示刷新率'));
    });
  }

  test('parallel UI and raster stages are not added to judge 60 Hz', () {
    final stats = FrameStats.forTesting(
      timings: _frames(fps: 60, buildMs: 12, rasterMs: 12),
    );
    addTearDown(stats.dispose);
    expect(stats.totalMs, 24); // Preserve the existing combined-work API.
    expect(stats.worstMs, 24);
    expect(stats.pipelineMs, 12);
    expect(stats.worstStageMs, 12);
    expect(frameBudgetVerdict(stats), '低帧符合显示刷新率，最慢阶段余量 4.7 ms');
  });

  test(
    'the same stage can exceed a 120 Hz budget despite a fast average cadence',
    () {
      final stats = FrameStats.forTesting(
        timings: _frames(fps: 120, buildMs: 12, rasterMs: 4),
        refreshRate: 120,
      );
      addTearDown(stats.dispose);
      expect(frameBudgetVerdict(stats), '最慢阶段超出显示刷新预算');
      expect(
        frameBudgetHealth(
          live: true,
          refreshRate: 120,
          lowFps: stats.lowFps,
          pipelineMs: stats.pipelineMs,
        ),
        FrameBudgetHealth.overBudget,
      );
    },
  );

  for (final sample in [
    (fps: 55.0, health: FrameBudgetHealth.nearBudget, verdict: '低帧接近显示刷新率'),
    (fps: 45.0, health: FrameBudgetHealth.overBudget, verdict: '低帧未达到显示刷新率'),
  ]) {
    test('low cadence ${sample.fps} is relative to a 60 Hz display', () {
      final stats = FrameStats.forTesting(timings: _frames(fps: sample.fps));
      addTearDown(stats.dispose);
      expect(
        frameBudgetHealth(
          live: true,
          refreshRate: 60,
          lowFps: stats.lowFps,
          pipelineMs: stats.pipelineMs,
        ),
        sample.health,
      );
      expect(frameBudgetVerdict(stats), sample.verdict);
    });
  }

  test('missing or invalid display refresh rates fall back to 60 Hz', () {
    for (final rate in [0.0, -1.0, double.nan, double.infinity]) {
      final stats = FrameStats.forTesting(
        timings: _frames(fps: 60),
        refreshRate: rate,
      );
      expect(stats.refreshRate, 60);
      expect(stats.budgetMs, closeTo(16.667, .001));
      expect(frameBudgetVerdict(stats), startsWith('低帧符合显示刷新率'));
      stats.dispose();
    }
    expect(displayFps(360), 360);
    expect(displayFps(double.nan), 0);
  });

  test('idle and incomplete measurements make no throughput claim', () {
    final stats = FrameStats.forTesting(
      timings: _frames(fps: 60).take(1).toList(),
    );
    addTearDown(stats.dispose);
    expect(frameBudgetVerdict(stats), '等待播放或动画的帧数据');
    expect(
      frameBudgetHealth(
        live: false,
        refreshRate: 60,
        lowFps: 60,
        pipelineMs: 2,
      ),
      FrameBudgetHealth.waiting,
    );
  });

  testWidgets('meter uses its own view refresh rate and fits a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.resetRefreshRate);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [FrameStatsOverlay()])),
      ),
    );
    expect(FrameStats.instance.refreshRate, 120);
    expect(find.text('预算 8.3 ms'), findsOneWidget);
    for (final element in find.byType(Text).evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(rect.right, lessThanOrEqualTo(308));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('logs describe uncapped backgrounds without reporting zero fps', () {
    SharedPreferences.setMockInitialValues({});
    final state = AppState()
      ..browseBackgroundFps = 0
      ..playerBackgroundFps = 0;
    addTearDown(state.dispose);
    final report = diagnosticReport(state);
    expect(
      RegExp('uncapped \\(display refresh rate\\)').allMatches(report),
      hasLength(2),
    );
    expect(report, isNot(contains('0 fps')));
    state.browseBackgroundFps = 120;
    expect(diagnosticReport(state), contains(', 120.0 fps'));
  });
}
