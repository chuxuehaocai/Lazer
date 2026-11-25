import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../animation/lazer_shader_warmup.dart';

/// Desktop bindings for Lazer.
///
/// This used to install a hand-written `SemanticsUpdateBuilder` that filtered
/// "orphan" `updateNode` calls out of every batch, to keep the Windows
/// accessibility bridge from rejecting a delta that referenced a detached node.
/// The filter made things worse: dropping a node the engine had already attached
/// leaves it pending forever, and the bridge then reported
/// `Nodes left pending by the update: 7 8 9 …` on every frame (thousands of
/// lines per minute, and `N will not be in the tree` whenever a page changed).
///
/// The framework's own batches are self-consistent; a node that is detached and
/// dirty is the engine's job to reconcile. So the default builder is used now,
/// and the lyric viewport keeps its single live-region semantics node so the
/// sheet no longer churns a node per visible line.
class LazerWidgetsBinding extends WidgetsFlutterBinding {
  @override
  void initInstances() {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      PaintingBinding.shaderWarmUp = const LazerShaderWarmUp();
    }
    super.initInstances();
  }
}
