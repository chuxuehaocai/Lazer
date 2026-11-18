// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../l10n/app_localizations.dart';
import '../state/build_safe_notifier.dart';
import '../theme/font_preferences.dart';
import '../theme/tokens.dart';

/// Rolling frame-time statistics from the engine's own timings callback.
///
/// Vsync timestamps of completed frames reveal cadence gaps; they are not
/// presentation timestamps or a promise that an idle UI renders continuously.
/// The overlay is opt-in because it rebuilds when new
/// timing batches arrive. Measurements remain driven by every completed frame;
/// the overlay itself updates four times a second so it does not force a new
/// frame or churn the Windows accessibility tree for every sample.
class FrameStats extends ChangeNotifier with BuildSafeNotifier {
  FrameStats._() : _refreshRateOverride = null;

  /// Detached timing sample for deterministic diagnostics tests.
  @visibleForTesting
  FrameStats.forTesting({
    required List<FrameTiming> timings,
    double refreshRate = 60,
  }) : _refreshRateOverride = refreshRate {
    _running = true;
    _onTimings(timings);
  }

  static final FrameStats instance = FrameStats._();

  final double? _refreshRateOverride;
  ui.FlutterView? _view;

  /// Refresh rate of the view displaying the meter, with a safe fallback for
  /// platforms that do not report a usable display rate.
  double get refreshRate => validDisplayRefreshRate(
    _refreshRateOverride ??
        _view?.display.refreshRate ??
        ui.PlatformDispatcher.instance.implicitView?.display.refreshRate ??
        60,
  );
  double get budgetMs => 1000 / refreshRate;

  static const int _window = 150;
  static const Duration _notifyEvery = Duration(milliseconds: 250);

  final List<FrameTiming> _frames = <FrameTiming>[];
  bool _running = false;
  int _lastNotifyMicros = 0;
  int _lastTimingMicros = 0;

  bool get running => _running;

  /// Whether a frame was measured recently enough to describe the live UI.
  bool get live =>
      _frames.isNotEmpty &&
      DateTime.now().microsecondsSinceEpoch - _lastTimingMicros < 1000000;

  /// Completed-frame cadence over the measured vsync window.
  double get fps {
    if (_frames.length < 2) return 0;
    final int first = _frames.first.timestampInMicroseconds(
      ui.FramePhase.vsyncStart,
    );
    final int last = _frames.last.timestampInMicroseconds(
      ui.FramePhase.vsyncStart,
    );
    final int span = last - first;
    if (span <= 0) return 0;
    return (_frames.length - 1) * 1000000 / span;
  }

  /// Fifth-percentile refresh rate over the rolling window. This exposes
  /// sustained low-frame behavior that an average FPS can hide.
  double get lowFps {
    if (_frames.length < 3) return 0;
    final List<int> intervals = <int>[
      for (var i = 1; i < _frames.length; i++)
        _frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
            _frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
    ]..sort();
    final int p95 = intervals[((intervals.length - 1) * .95).ceil()];
    return p95 <= 0 ? 0 : 1000000 / p95;
  }

  double get buildMs =>
      _average(ui.FramePhase.buildFinish, ui.FramePhase.buildStart);
  double get rasterMs =>
      _average(ui.FramePhase.rasterFinish, ui.FramePhase.rasterStart);

  /// Combined CPU work, retained for existing diagnostic consumers. UI and
  /// raster threads overlap; this sum is not the display's frame budget.
  double get totalMs => buildMs + rasterMs;
  double get pipelineMs => math.max(buildMs, rasterMs);

  /// Longest combined work sample. Use [worstStageMs] for pipeline throughput.
  double get worstMs {
    if (_frames.isEmpty) return 0;
    double worst = 0;
    for (final FrameTiming frame in _frames) {
      final double total =
          (frame.buildDuration.inMicroseconds +
              frame.rasterDuration.inMicroseconds) /
          1000;
      if (total > worst) worst = total;
    }
    return worst;
  }

  /// Slowest UI or raster stage, without adding parallel pipeline stages.
  double get worstStageMs {
    var worst = 0;
    for (final frame in _frames) {
      worst = math.max(
        worst,
        math.max(
          frame.buildDuration.inMicroseconds,
          frame.rasterDuration.inMicroseconds,
        ),
      );
    }
    return worst / 1000;
  }

  double _average(ui.FramePhase end, ui.FramePhase start) {
    if (_frames.isEmpty) return 0;
    var sum = 0;
    for (final FrameTiming frame in _frames) {
      sum +=
          frame.timestampInMicroseconds(end) -
          frame.timestampInMicroseconds(start);
    }
    return sum / _frames.length / 1000;
  }

  void start({ui.FlutterView? view}) {
    if (view != null) _view = view;
    if (_running) return;
    _running = true;
    _frames.clear();
    _lastNotifyMicros = 0;
    _lastTimingMicros = 0;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    notifyListeners();
  }

  void stop() {
    if (!_running) return;
    _running = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    notifyListeners();
  }

  void _onTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    _frames.addAll(timings);
    // Keep a rolling one-second sample, not merely the last 150 frames: after
    // the UI goes idle the old window would otherwise report a bogus low FPS
    // across the idle gap.
    final int lastVsync = timings.last.timestampInMicroseconds(
      ui.FramePhase.vsyncStart,
    );
    final int cutoff = lastVsync - 1000000;
    _frames.removeWhere(
      (FrameTiming frame) =>
          frame.timestampInMicroseconds(ui.FramePhase.vsyncStart) < cutoff,
    );
    if (_frames.length > _window) {
      _frames.removeRange(0, _frames.length - _window);
    }
    _lastTimingMicros = DateTime.now().microsecondsSinceEpoch;
    if (_lastTimingMicros - _lastNotifyMicros < _notifyEvery.inMicroseconds) {
      return;
    }
    _lastNotifyMicros = _lastTimingMicros;
    notifyListeners();
  }

  static String formatMs(double value) {
    if (value <= 0) return '—';
    return value < 10
        ? '${value.toStringAsFixed(1)} ms'
        : '${value.round()} ms';
  }
}

/// The opt-in meter compares measured cadence and the slowest pipeline stage
/// with the display that hosts it, without imposing an application FPS cap.
class FrameStatsOverlay extends StatefulWidget {
  const FrameStatsOverlay({super.key});

  @override
  State<FrameStatsOverlay> createState() => _FrameStatsOverlayState();
}

class _FrameStatsOverlayState extends State<FrameStatsOverlay> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    FrameStats.instance.start(view: View.of(context));
  }

  @override
  void dispose() {
    FrameStats.instance.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 12,
      right: 12,
      top: 12,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: FrameStats.instance,
              builder: (BuildContext context, _) {
                final FrameStats stats = FrameStats.instance;
                final bool live = stats.live;
                final double budget = stats.budgetMs;
                final double lowFps = stats.lowFps;
                final Color tone = switch (frameBudgetHealth(
                  live: live,
                  refreshRate: stats.refreshRate,
                  lowFps: lowFps,
                  pipelineMs: stats.pipelineMs,
                )) {
                  FrameBudgetHealth.waiting => const Color(0xFF87949A),
                  FrameBudgetHealth.withinBudget => const Color(0xFF66D39B),
                  FrameBudgetHealth.nearBudget => const Color(0xFFE8C46A),
                  FrameBudgetHealth.overBudget => const Color(0xFFE88A8A),
                };
                return Material(
                  color: const Color(0xE6141C20),
                  elevation: 2,
                  borderRadius: AppShape.mdRadius,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: DefaultTextStyle(
                      style: context.fonts.apply(
                        FontCategory.caption,
                        const TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: Color(0xFFE2E8E9),
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: tone,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Text(
                            stats.live && stats.fps > 0
                                ? '${stats.fps.toStringAsFixed(0)} fps'
                                : context.tr('帧率 —'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            stats.live && lowFps > 0
                                ? context.tr('低帧 ${lowFps.toStringAsFixed(0)}')
                                : context.tr('低帧 —'),
                            style: TextStyle(color: tone),
                          ),
                          Text(
                            'UI ${FrameStats.formatMs(live ? stats.buildMs : 0)}',
                          ),
                          Text(
                            'Raster ${FrameStats.formatMs(live ? stats.rasterMs : 0)}',
                          ),
                          Text(
                            context.tr('预算 ${FrameStats.formatMs(budget)}'),
                            style: TextStyle(color: tone),
                          ),
                          Text(
                            context.tr(
                              '阶段峰值 ${FrameStats.formatMs(live ? stats.worstStageMs : 0)}',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// A one-line description of measured work and cadence relative to the
/// current display; a fast sample is not a guarantee of future throughput.
String frameBudgetVerdict(FrameStats stats) {
  if (!stats.running || !stats.live || stats.lowFps <= 0) {
    return '等待播放或动画的帧数据';
  }
  final double budget = stats.budgetMs;
  if (stats.pipelineMs > budget) return '最慢阶段超出显示刷新预算';
  return switch (frameBudgetHealth(
    live: true,
    refreshRate: stats.refreshRate,
    lowFps: stats.lowFps,
    pipelineMs: stats.pipelineMs,
  )) {
    FrameBudgetHealth.withinBudget =>
      '低帧符合显示刷新率，最慢阶段余量 ${(budget - stats.pipelineMs).toStringAsFixed(1)} ms',
    FrameBudgetHealth.nearBudget => '低帧接近显示刷新率',
    FrameBudgetHealth.overBudget => '低帧未达到显示刷新率',
    FrameBudgetHealth.waiting => '等待播放或动画的帧数据',
  };
}

enum FrameBudgetHealth { waiting, withinBudget, nearBudget, overBudget }

/// Timing jitter has a small tolerance, while the actual stage budget remains
/// one display interval. This is a diagnosis, never a scheduler or frame cap.
FrameBudgetHealth frameBudgetHealth({
  required bool live,
  required double refreshRate,
  required double lowFps,
  required double pipelineMs,
}) {
  if (!live || !lowFps.isFinite || lowFps <= 0 || !pipelineMs.isFinite) {
    return FrameBudgetHealth.waiting;
  }
  final rate = validDisplayRefreshRate(refreshRate);
  final budget = 1000 / rate;
  if (lowFps >= rate * .95 && pipelineMs <= budget) {
    return FrameBudgetHealth.withinBudget;
  }
  if (lowFps >= rate * .9 && pipelineMs <= budget / .9) {
    return FrameBudgetHealth.nearBudget;
  }
  return FrameBudgetHealth.overBudget;
}

double validDisplayRefreshRate(double rate) =>
    rate.isFinite && rate > 0 ? rate : 60;

/// Clamp a measured rate for display, without an arbitrary upper limit.
int displayFps(double fps) => fps.isFinite ? math.max(0, fps.round()) : 0;
