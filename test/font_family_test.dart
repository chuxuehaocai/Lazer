import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/theme/imported_font.dart';
import 'package:lazer_nextgen/diagnostics/frame_stats.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('imported fonts survive source switching and restore in themes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('lazer-font-');
      try {
        final bytes = await File(
          'assets/fonts/MiSans-Regular.ttf',
        ).readAsBytes();
        final imported = await ImportedFont.importFile(
          bytes,
          'Custom.ttf',
          storageDirectory: directory,
        );
        expect(await File(imported.path!).readAsBytes(), bytes);
        expect(imported.source, FontSource.imported);
        final state = AppState();
        try {
          await state.setFontFamily(imported);
          await state.setFontCustomization(
            FontCategory.body,
            const FontCustomization(scale: 1.2),
          );
          final prefs = await SharedPreferences.getInstance();
          final restored = FontPreferences.decode(
            prefs.getString('lazer_font_preferences'),
          );
          expect(restored.family.family, imported.family);
          expect(restored.family.path, imported.path);
          for (final theme in [
            buildAppleTheme(fonts: restored),
            buildAppleTheme(brightness: Brightness.dark, fonts: restored),
          ]) {
            expect(theme.textTheme.bodyLarge!.fontFamily, imported.family);
          }
          await state.setFontFamily(imported.withSource(FontSource.system));
          expect(state.fontPreferences.family.path, imported.path);
          expect(state.fontPreferences.family.resolvedFamily, isNot('MiSans'));
          await state.setFontFamily(
            state.fontPreferences.family.withSource(FontSource.imported),
          );
          expect(state.fontPreferences.family.family, imported.family);
          await state.resetFonts();
          expect(state.fontPreferences.family.source, FontSource.miSans);
        } finally {
          state.dispose();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  test('corrupt sfnt files are rejected before changing the font', () {
    final bytes = File('assets/fonts/MiSans-Regular.ttf').readAsBytesSync();
    expect(
      () => ImportedFont.validate(bytes.sublist(0, 12)),
      throwsFormatException,
    );
    expect(
      () => ImportedFont.validate(bytes.sublist(0, 100)),
      throwsFormatException,
    );
    final original = const FontPreferences({
      FontCategory.title: FontCustomization(scale: 1.2),
    });
    final decoded = FontPreferences.decode(original.encode());
    expect(decoded.family.source, FontSource.miSans);
    expect(decoded[FontCategory.title].scale, 1.2);
  });

  test('system fonts use the device fallback for all scripts', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const preferences = FontPreferences(
      {},
      FontFamilyPreference(source: FontSource.system),
    );
    expect(preferences.family.resolvedFamily, 'sans-serif');
    for (final theme in [
      buildAppleTheme(fonts: preferences),
      buildAppleTheme(brightness: Brightness.dark, fonts: preferences),
    ]) {
      expect(theme.textTheme.bodyLarge!.fontFamily, 'sans-serif');
      expect(theme.textTheme.bodyLarge!.fontFamilyFallback, isEmpty);
    }
    expect(
      preferences
          .apply(
            FontCategory.playerTitle,
            const TextStyle(
              fontFamily: 'MiSans',
              fontFamilyFallback: ['MiSans'],
            ),
          )
          .fontFamilyFallback,
      isEmpty,
    );
  });

  testWidgets('frame meter inherits the selected font family', (tester) async {
    const preferences = FontPreferences(
      {},
      FontFamilyPreference(source: FontSource.system),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(fonts: preferences),
        home: const Scaffold(body: Stack(children: [FrameStatsOverlay()])),
      ),
    );
    final style = DefaultTextStyle.of(
      tester.element(find.textContaining('UI ')),
    ).style;
    expect(style.fontFamily, preferences.family.resolvedFamily);
    expect(style.fontFamilyFallback, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(FrameStats.instance.running, isFalse);
  });

  testWidgets('a slow imported face cannot override a later font selection', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final state = AppState();
      final directory = await Directory.systemTemp.createTemp(
        'lazer-font-race-',
      );
      try {
        final file = await File(
          'assets/fonts/MiSans-Regular.ttf',
        ).copy('${directory.path}${Platform.pathSeparator}race.ttf');
        final pending = state.setFontFamily(
          FontFamilyPreference(
            source: FontSource.imported,
            family: 'LazerSlowImport',
            path: file.path,
          ),
        );
        await state.setFontFamily(
          const FontFamilyPreference(source: FontSource.system),
        );
        await pending;
        expect(state.fontPreferences.family.source, FontSource.system);
        final saved = FontPreferences.decode(
          (await SharedPreferences.getInstance()).getString(
            'lazer_font_preferences',
          ),
        );
        expect(saved.family.source, FontSource.system);
      } finally {
        state.dispose();
        await directory.delete(recursive: true);
      }
    });
  });
}
