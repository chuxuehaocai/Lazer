import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../utils/artwork.dart';
import '../utils/media_requests.dart';
import '../utils/system_http.dart';

const _maxSourceBytes = 4 * 1024 * 1024;

/// One thumbnail, capped before decoding and released immediately afterwards.
Future<Uint8List?> loadWidgetArtwork(
  String source, {
  http.Client Function()? clientFactory,
}) async {
  final normalized = enlargedArtworkUrl(source, sizePx: 256);
  if (normalized == null) return null;
  final uri = Uri.parse(normalized);
  Uint8List? bytes;
  if (uri.scheme == 'file') {
    final file = File.fromUri(uri);
    if (await file.length() > _maxSourceBytes) return null;
    bytes = await _readBounded(file.openRead());
  } else {
    final client = (clientFactory ?? openExternalClient)();
    try {
      final request = http.Request('GET', uri)
        ..headers.addAll(MediaRequestRules.headers(normalized));
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > _maxSourceBytes) {
        return null;
      }
      bytes = await _readBounded(
        response.stream,
      ).timeout(const Duration(seconds: 4));
    } finally {
      client.close();
    }
  }
  if (bytes == null) return null;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = math.min(
      1.0,
      256 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<Uint8List?> _readBounded(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > _maxSourceBytes) return null;
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
