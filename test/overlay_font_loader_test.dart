import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_font_loader.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'custom font budget bounds registrations while repeated families reuse one load',
    () async {
      final loader = OverlayFontLoader();
      const path = 'assets/fonts/RobotoMono-Regular.ttf';
      final first = loader.load('Budget0', path);
      expect(identical(first, loader.load('Budget0', path)), isTrue);
      await first;
      for (var i = 1; i < kOverlayCustomFontLimit; i++) {
        await loader.load('Budget$i', path);
      }
      await expectLater(loader.load('BudgetOverflow', path), throwsStateError);
      await loader.load('Budget0', path);
    },
  );

  test(
    'failed font reads release budget for a later valid selection',
    () async {
      final loader = OverlayFontLoader();
      for (var i = 0; i <= kOverlayCustomFontLimit; i++) {
        await expectLater(
          loader.load('Missing$i', 'not-a-font-file.ttf'),
          throwsA(isA<FileSystemException>()),
        );
      }
      await loader.load('RetrySuccess', 'assets/fonts/RobotoMono-Regular.ttf');
    },
  );

  test(
    'oversized custom font is rejected before allocating its byte buffer',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-overlay-font-',
      );
      try {
        final file = File('${directory.path}/oversized.ttf');
        final handle = await file.open(mode: FileMode.write);
        await handle.truncate(kOverlayMaximumFontBytes + 1);
        await handle.close();
        await expectLater(
          OverlayFontLoader().load('Oversized', file.path),
          throwsStateError,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
