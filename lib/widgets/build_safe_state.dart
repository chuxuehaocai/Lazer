import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Keeps local state changes synchronous while scheduling dirty elements only
/// when Flutter can visit them. A controller, image, focus or layout callback
/// can run while an unrelated retained subtree is being built.
///
/// Pointer events and animation ticks still rebuild immediately. Only updates
/// inside the frame's build/layout/paint phase or its microtasks are coalesced.
mixin BuildSafeState<T extends StatefulWidget> on State<T> {
  bool _buildSafeRebuildScheduled = false;

  @override
  void setState(VoidCallback fn) {
    final scheduler = SchedulerBinding.instance;
    final phase = scheduler.schedulerPhase;
    if (!mounted ||
        (phase != SchedulerPhase.persistentCallbacks &&
            phase != SchedulerPhase.midFrameMicrotasks)) {
      // Preserve State's normal lifecycle checks, including after disposal.
      super.setState(fn);
      return;
    }
    // Delaying fn itself can reorder selection, playback or gesture state.
    // Apply it now and postpone only the framework's markNeedsBuild call.
    final Object? result = fn() as dynamic;
    assert(() {
      if (result is Future) {
        throw FlutterError(
          'setState() callback argument returned a Future. '
          'Complete asynchronous work before updating widget state.',
        );
      }
      return true;
    }());
    if (_buildSafeRebuildScheduled) return;
    _buildSafeRebuildScheduled = true;
    scheduler.addPostFrameCallback((_) {
      _buildSafeRebuildScheduled = false;
      if (mounted) super.setState(() {});
    });
    scheduler.ensureVisualUpdate();
  }
}
