// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../l10n/app_localizations.dart';
import '../state/build_safe_notifier.dart';
import '../theme/tokens.dart';

/// Rolling frame-time statistics from the engine's own timings callback.
///
/// This is the honest number: it measures the frames Flutter actually built
/// and rasterised, including dropped frames, rather than an animation's
/// nominal duration. The overlay is opt-in because it rebuilds when new
/// timing batches arrive. Measurements remain driven by every completed frame;
/// the overlay itself updates four times a second so it does not force a new
/// frame or churn the Windows accessibility tree for every sample.
class FrameStats extends ChangeNotifier with BuildSafeNotifier {
  FrameStats._();

  static final FrameStats instance = FrameStats._();

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

  /// Frames presented per second over the measured window.
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
  double get totalMs => buildMs + rasterMs;

  /// Longest total frame in the window — the one that decides whether the UI
  /// can sustain the target refresh rate.
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

  void start() {
    if (_running) return;
    _running = true;
    _frames.clear();
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

/// The opt-in frame meter. Green means the whole frame fits the 100 fps
/// budget, amber means it stays above the 90 fps floor, red means it does not.
class FrameStatsOverlay extends StatefulWidget {
  const FrameStatsOverlay({super.key});

  @override
  State<FrameStatsOverlay> createState() => _FrameStatsOverlayState();
}

class _FrameStatsOverlayState extends State<FrameStatsOverlay> {
  @override
  void initState() {
    super.initState();
    FrameStats.instance.start();
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
      top: 12,
      child: SafeArea(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: FrameStats.instance,
            builder: (BuildContext context, _) {
              final FrameStats stats = FrameStats.instance;
              final bool live = stats.live;
              final double budget = AppMotion.frameBudgetMs;
              final double total = stats.totalMs;
              final double lowFps = stats.lowFps;
              final Color tone = !live
                  ? const Color(0xFF87949A)
                  : lowFps > 0 && lowFps < 90
                  ? const Color(0xFFE88A8A)
                  : lowFps > 0 && lowFps < 100
                  ? const Color(0xFFE8C46A)
                  : total <= budget
                  ? const Color(0xFF66D39B)
                  : total <= 1000 / 60
                  ? const Color(0xFFE8C46A)
                  : const Color(0xFFE88A8A);
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
                    style: const TextStyle(
                      fontFamily: AppFonts.sans,
                      fontSize: 11,
                      height: 1.5,
                      color: Color(0xFFE2E8E9),
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: tone,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          stats.live && stats.fps > 0
                              ? '${stats.fps.toStringAsFixed(0)} fps'
                              : context.tr('帧率 —'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          stats.live && lowFps > 0
                              ? context.tr('低帧 ${lowFps.toStringAsFixed(0)}')
                              : context.tr('低帧 —'),
                          style: TextStyle(color: tone),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'UI ${FrameStats.formatMs(live ? stats.buildMs : 0)}',
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'GPU ${FrameStats.formatMs(live ? stats.rasterMs : 0)}',
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.tr('预算 ${FrameStats.formatMs(budget)}'),
                          style: TextStyle(color: tone),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.tr(
                            '峰值 ${FrameStats.formatMs(live ? stats.worstMs : 0)}',
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
    );
  }
}

/// A one-line verdict for the settings page, measured against the 100 fps
/// budget the animations are tuned for.
String frameBudgetVerdict(FrameStats stats) {
  if (!stats.running || !stats.live) return '等待播放或动画的帧数据';
  final double budget = AppMotion.frameBudgetMs;
  final double total = stats.totalMs;
  if (total <= budget) {
    return '余量 ${(budget - total).toStringAsFixed(1)} ms，可支撑 100 fps';
  }
  if (stats.lowFps >= 90) return '低帧达到 90 fps，未达到 100 fps 预算';
  return '低帧低于 90 fps';
}

/// Clamp a measured rate for display.
int displayFps(double fps) => math.max(0, fps.round());
