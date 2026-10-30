// Compile into the bundle, then run from an unrelated working directory.
import 'dart:io';

import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';

Future<void> main(List<String> arguments) async {
  try {
    final availability = LazerAudioLoader.load();
    if (arguments.contains('--expect-unavailable')) {
      if (availability.isAvailable) {
        throw StateError('Unexpected native engine outside bundle');
      }
      stdout.writeln(
        'Native engine unavailable; system fallback can be selected: ${availability.reason}',
      );
      return;
    }
    if (!availability.supportsStreaming) {
      throw StateError(availability.reason ?? 'Reader bridge missing');
    }
    stdout.writeln(availability.api!.buildInformation());
    final worker = await LazerAudioWorker.spawn().timeout(
      const Duration(seconds: 15),
    );
    try {
      final handle = await worker.call(LazerWorkerOp.create, [
        ...const LazerDeviceSettings().toDeviceMessage(),
        0,
        0,
      ]);
      if (handle is! int || handle == 0) {
        throw StateError('Native engine creation failed');
      }
      await worker.call(LazerWorkerOp.destroy, [handle]);
    } finally {
      await worker.close();
    }
    stdout.writeln('Native engine and reader bridge load in both isolates.');
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  }
}
