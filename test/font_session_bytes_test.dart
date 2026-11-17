import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_font_loader.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/theme/imported_font.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final overlay in [false, true]) {
    test(
      '${overlay ? 'overlay' : 'main'} reserves bytes before concurrent reads and releases failed loads',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'lazer-font-bytes-',
        );
        try {
          final file = File('${directory.path}/large-valid-header.ttf');
          final header = Uint8List(28);
          final data = ByteData.sublistView(header);
          data.setUint32(0, 0x00010000);
          data.setUint16(4, 1);
          await file.writeAsBytes(header);
          final handle = await file.open(mode: FileMode.append);
          await handle.truncate(40 * 1024 * 1024);
          await handle.close();
          final started = Completer<void>();
          final blocked = Completer<void>();
          var registrations = 0;
          Future<void> register() async {
            registrations++;
            if (registrations == 1) {
              started.complete();
              await blocked.future;
              throw StateError('first registration rejected');
            }
          }

          late Future<void> Function(String) load;
          if (overlay) {
            final loader = OverlayFontLoader(register: (_, _) => register());
            load = (family) => loader.load(family, file.path);
          } else {
            final session = ImportedFontSession(register: (_, _) => register());
            load = (family) => session.load(
              FontFamilyPreference(
                source: FontSource.imported,
                family: family,
                path: file.path,
              ),
            );
          }
          final first = expectLater(load('first'), throwsStateError);
          await started.future;
          final exhausted = overlay
              ? isA<StateError>()
              : isA<FontImportException>().having(
                  (e) => e.failure,
                  'failure',
                  FontImportFailure.sessionLimit,
                );
          await expectLater(load('second'), throwsA(exhausted));
          expect(registrations, 1); // the rejected second font never registers
          blocked.complete();
          await first;
          await load('second'); // failure released the first 40 MiB reservation
          expect(registrations, 2);
          await load(
            'second',
          ); // reusing a loaded family consumes zero new bytes
          await expectLater(load('third'), throwsA(exhausted));
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
