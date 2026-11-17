import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/theme/imported_font.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/font_settings_page.dart';

class _RejectedFontState extends AppState {
  _RejectedFontState(this.failure);
  final FontImportFailure failure;
  @override
  Future<void> setFontFamily(FontFamilyPreference value) async {
    throw FontImportException(failure);
  }
}

Uint8List _fontHeader() {
  final bytes = Uint8List(28);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x00010000);
  data.setUint16(4, 1);
  return bytes;
}

FontFamilyPreference _family(int i) => FontFamilyPreference(
  source: FontSource.imported,
  family: 'Session$i',
  path: 'fixture-$i.ttf',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'eight completed or in-flight families consume the same bounded budget',
    () async {
      final blocked = Completer<void>();
      final calls = <String>[];
      final session = ImportedFontSession(
        register: (family, bytes) async {
          calls.add(family);
          await blocked.future;
        },
      );
      final bytes = _fontHeader();
      final pending = [
        for (var i = 0; i < ImportedFontSession.maximumFamilies; i++)
          session.load(_family(i), bytes: bytes),
      ];
      expect(
        identical(pending.first, session.load(_family(0), bytes: bytes)),
        isTrue,
      );
      await expectLater(
        session.load(_family(8), bytes: bytes),
        throwsA(
          isA<FontImportException>().having(
            (e) => e.failure,
            'failure',
            FontImportFailure.sessionLimit,
          ),
        ),
      );
      expect(calls, hasLength(8));
      blocked.complete();
      await Future.wait(pending);
      await session.load(_family(0), bytes: bytes);
      expect(calls, hasLength(8));
      await expectLater(
        session.load(_family(9), bytes: bytes),
        throwsA(isA<FontImportException>()),
      );
    },
  );

  test(
    'failed validation and failed registration release their reserved slot',
    () async {
      var fail = true;
      final session = ImportedFontSession(
        register: (_, _) async {
          if (fail) throw StateError('font engine rejected fixture');
        },
      );
      await expectLater(
        session.load(_family(0), bytes: Uint8List(2)),
        throwsFormatException,
      );
      await expectLater(
        session.load(_family(0), bytes: _fontHeader()),
        throwsStateError,
      );
      fail = false;
      await session.load(_family(0), bytes: _fontHeader());
    },
  );

  test(
    'oversized lazy file is rejected before reading into Dart memory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-import-font-',
      );
      try {
        final file = File('${directory.path}/large.ttf');
        final handle = await file.open(mode: FileMode.write);
        await handle.truncate(ImportedFont.maximumFileBytes + 1);
        await handle.close();
        await expectLater(
          ImportedFont.readSelection(XFile(file.path)),
          throwsA(
            isA<FontImportException>().having(
              (e) => e.failure,
              'failure',
              FontImportFailure.tooLarge,
            ),
          ),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'rejected ninth family preserves both current preference and persisted selection',
    () async {
      final state = AppState();
      try {
        for (var i = 0; i < ImportedFontSession.maximumFamilies; i++) {
          await state.setFontFamily(
            FontFamilyPreference(
              source: FontSource.imported,
              family: 'Persisted$i',
              path: 'assets/fonts/RobotoMono-Regular.ttf',
            ),
          );
        }
        final selected = state.fontPreferences.family;
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString('lazer_font_preferences');
        await expectLater(
          state.setFontFamily(
            const FontFamilyPreference(
              source: FontSource.imported,
              family: 'PersistedOverflow',
              path: 'assets/fonts/RobotoMono-Regular.ttf',
            ),
          ),
          throwsA(isA<FontImportException>()),
        );
        expect(state.fontPreferences.family, same(selected));
        expect(prefs.getString('lazer_font_preferences'), saved);
      } finally {
        state.dispose();
      }
    },
  );

  for (final failure in FontImportFailure.values) {
    testWidgets(
      'font settings explain ${failure.name} and preserve selection',
      (tester) async {
        final state = _RejectedFontState(failure);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            home: FontSettingsPage(state: state),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('font-family-selector')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('系统字体'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            failure == FontImportFailure.sessionLimit
                ? '本次启动已达到自定义字体加载上限，请重新启动后继续切换字体。'
                : '字体文件不能超过 64 MiB，请选择较小的字体文件。',
          ),
          findsOneWidget,
        );
        expect(state.fontPreferences.family.source, FontSource.miSans);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
}
