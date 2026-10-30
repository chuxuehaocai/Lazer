import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'semantics_transaction.dart';
import '../animation/lazer_shader_warmup.dart';

class LazerWidgetsBinding extends WidgetsFlutterBinding {
  @override
  void initInstances() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      PaintingBinding.shaderWarmUp = const LazerShaderWarmUp();
    }
    super.initInstances();
  }

  final SemanticsTransaction _transaction = SemanticsTransaction();
  Map<String, int> get semanticsDiagnostics => {
    'detached_updates_removed': _transaction.orphanUpdates,
    'reattached_nodes_restored': _transaction.restoredNodes,
  };

  LazerWidgetsBinding() {
    addSemanticsEnabledListener(() {
      if (!semanticsEnabled) _transaction.reset();
    });
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS
      ? TransactionalSemanticsBuilder(_transaction)
      : super.createSemanticsUpdateBuilder();
}
