// WAV fixtures for the native-engine checks.
//
// The engine's reader opens a *file*, so the checks that need a decodable source
// without shipping a binary fixture build one: 16-bit PCM WAV is the one format
// whose framing is simple enough to emit by hand and whose runtime (FFmpeg) is
// already a hard dependency of the engine.
import 'dart:typed_data';

/// A 2-channel 16-bit PCM WAV of [millis] of silence.
Uint8List wavFixture(
  int millis, {
  int sampleRate = 44100,
  int channels = 2,
}) {
  final int frames = sampleRate * millis ~/ 1000;
  final int dataBytes = frames * channels * 2;
  final BytesBuilder body = BytesBuilder();
  body.add(_ascii('RIFF'));
  body.add(_uint32(36 + dataBytes));
  body.add(_ascii('WAVEfmt '));
  body.add(_uint32(16));
  body.add(_uint16(1)); // PCM
  body.add(_uint16(channels));
  body.add(_uint32(sampleRate));
  body.add(_uint32(sampleRate * channels * 2)); // byte rate
  body.add(_uint16(channels * 2)); // block align
  body.add(_uint16(16)); // bits per sample
  body.add(_ascii('data'));
  body.add(_uint32(dataBytes));
  body.add(Uint8List(dataBytes));
  return body.takeBytes();
}

Uint8List _ascii(String text) =>
    Uint8List.fromList(text.codeUnits.map((int c) => c & 0xff).toList());

Uint8List _uint16(int value) =>
    Uint8List.fromList(<int>[value & 0xff, (value >> 8) & 0xff]);

Uint8List _uint32(int value) => Uint8List.fromList(<int>[
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
]);
