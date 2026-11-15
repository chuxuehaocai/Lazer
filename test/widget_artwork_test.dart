import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lazer_nextgen/platform/widget_artwork_io.dart';

class _Client extends http.BaseClient {
  _Client(this.response);
  final http.StreamedResponse response;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
  @override
  void close() => closed = true;
}

Future<void> _picture(File file, int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint()..color = const ui.Color(0xffe83858));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async => directory = await Directory.systemTemp.createTemp(
      'lazer-widget-cover-',
    ),
  );
  tearDown(() => directory.delete(recursive: true));

  test(
    'widget covers preserve aspect ratio, cap dimensions, and never upscale',
    () async {
      for (final (width, height, expectedWidth, expectedHeight) in [
        (2048, 1024, 256, 128),
        (1024, 2048, 128, 256),
        (2048, 2048, 256, 256),
        (32, 16, 32, 16),
      ]) {
        final file = File('${directory.path}/$width-$height.png');
        await _picture(file, width, height);
        final bytes = await loadWidgetArtwork(file.uri.toString());
        expect(bytes, isNotNull);
        final codec = await ui.instantiateImageCodec(bytes!);
        final frame = await codec.getNextFrame();
        try {
          expect(
            (frame.image.width, frame.image.height),
            (expectedWidth, expectedHeight),
          );
          expect(
            frame.image.width * frame.image.height * 4,
            lessThanOrEqualTo(262144),
          );
        } finally {
          frame.image.dispose();
          codec.dispose();
        }
      }
    },
  );

  test('large local sources are rejected before decode', () async {
    final file = File('${directory.path}/too-large.png');
    final writer = await file.open(mode: FileMode.write);
    await writer.truncate(4 * 1024 * 1024 + 1);
    await writer.close();
    expect(await loadWidgetArtwork(file.uri.toString()), isNull);
  });

  test(
    'HTTP status and declared oversized bodies are rejected and clients close',
    () async {
      for (final (status, length) in [(404, 0), (200, 4 * 1024 * 1024 + 1)]) {
        final client = _Client(
          http.StreamedResponse(
            const Stream.empty(),
            status,
            contentLength: length,
          ),
        );
        expect(
          await loadWidgetArtwork(
            'https://example.test/cover',
            clientFactory: () => client,
          ),
          isNull,
        );
        expect(client.closed, isTrue);
      }
    },
  );

  test('chunked downloads cannot exceed the source byte budget', () async {
    final client = _Client(
      http.StreamedResponse(
        Stream.fromIterable(
          List.generate(5, (_) => List<int>.filled(1024 * 1024, 1)),
        ),
        200,
      ),
    );
    expect(
      await loadWidgetArtwork(
        'https://example.test/cover',
        clientFactory: () => client,
      ),
      isNull,
    );
    expect(client.closed, isTrue);
  });

  test('invalid schemes do not open a client', () async {
    expect(
      await loadWidgetArtwork(
        'data:image/png;base64,AA==',
        clientFactory: () => throw StateError('unexpected client'),
      ),
      isNull,
    );
  });
}
