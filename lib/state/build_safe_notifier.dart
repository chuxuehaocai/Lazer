import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// A [ChangeNotifier] that never marks an ancestor dirty from inside a build.
///
/// Several state objects are notified from `initState` (a page starting a
/// fetch) or from a focus change while the framework is building. A synchronous
/// `notifyListeners` there makes every `AnimatedBuilder` above the caller call
/// `setState` during build, which Flutter throws on. Notifications raised in
/// the build phase are folded into one post-frame callback instead; all other
/// phases keep the immediate behaviour listeners expect.
mixin BuildSafeNotifier on ChangeNotifier {
  bool _buildSafeDisposed = false;
  bool _buildSafeScheduled = false;

  @override
  void dispose() {
    _buildSafeDisposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_buildSafeDisposed) return;
    SchedulerPhase? phase;
    try {
      phase = SchedulerBinding.instance.schedulerPhase;
    } catch (_) {
      // No binding (pure unit tests): notify as usual.
      phase = null;
    }
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_buildSafeScheduled) return;
      _buildSafeScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _buildSafeScheduled = false;
        if (!_buildSafeDisposed) super.notifyListeners();
      });
      SchedulerBinding.instance.ensureVisualUpdate();
      return;
    }
    super.notifyListeners();
  }
}

/// Preserves synchronous value reads and equality checks while keeping
/// ValueListenableBuilder and other consumers safe during sibling builds.
class BuildSafeValueNotifier<T> extends ValueNotifier<T>
    with BuildSafeNotifier {
  BuildSafeValueNotifier(super.value);
}
