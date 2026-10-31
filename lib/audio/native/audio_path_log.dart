// The app-side sink for the `audio.path` records.
//
// The formatter is in `engine_selection.dart` (Flutter-free) so the `tool/`
// checks emit byte-identical lines; this file only decides where the app writes
// them. Records are one line each and carry the fields the HiFi work has to
// prove: which engine was selected, what the device catalog answered, and what
// format the output session actually negotiated.
library;

import 'package:flutter/foundation.dart';

import 'engine_selection.dart';

/// Emits one structured `audio.path` line through [debugPrint].
///
/// Deliberately not rate limited: these are per-event records (launch, device
/// enumeration, format negotiation), not per-buffer ones. Anything that runs on
/// the engine's render path must not call this — see the review checklist in
/// `docs/audio-engine-status.md`.
void logAudioPathEvent(
  String event, [
  Map<String, Object?> fields = const <String, Object?>{},
]) {
  debugPrint(formatAudioPathRecord(event, fields));
}
