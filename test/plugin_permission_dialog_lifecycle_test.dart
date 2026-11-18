import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

class _State extends AppState {
  _State() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.phone;
    backgroundMode = AppBackgroundMode.off;
  }

  @override
  Future<void> bootstrap() async {}
  @override
  bool get autoUpdateCheckDue => false;
}

class _Audio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

class _Media extends Fake implements SystemMediaController {
  @override
  void close() {}
}

class _Plugin extends Fake implements InstalledPlugin {
  @override
  final manifest = PluginManifest.fromJson({
    'id': 'permission.fixture',
    'provider': 'fixture',
    'name': 'Permission fixture',
    'version': '1.0.0',
    'apiVersion': 1,
    'permissions': {
      'data': ['library', 'profile'],
    },
  });
}

VoidCallback _response(AlertDialog dialog, bool allow) => allow
    ? dialog.actions!.whereType<FilledButton>().single.onPressed!
    : dialog.actions!.whereType<TextButton>().single.onPressed!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final allowFirst in [false, true]) {
    testWidgets(
      'a repeated permission response cannot answer the next request ($allowFirst)',
      (tester) async {
        await tester.runAsync(
          () => AppLocalizations.delegate.load(const Locale('en')),
        );
        final state = _State();
        await tester.pumpWidget(
          LazerApp(state: state, audio: _Audio(), media: _Media()),
        );
        await tester.pumpAndSettle();
        final request = state.pluginManager.onPermissionRequest!;
        final plugin = _Plugin();
        final first = request(plugin, 'data.library');
        bool? secondResult;
        final second = request(plugin, 'data.profile').then((value) {
          secondResult = value;
          return value;
        });
        await tester.pumpAndSettle();
        final firstDialog = tester.widget<AlertDialog>(
          find.byType(AlertDialog),
        );
        final respondAgain = _response(firstDialog, allowFirst);
        respondAgain();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        expect(await first, allowFirst);
        final secondDialog = tester
            .widgetList<AlertDialog>(
              find.byType(AlertDialog, skipOffstage: false),
            )
            .last;
        // The first route remains mounted during its reverse animation.
        respondAgain();
        await tester.pump();
        final prematurelyAnswered = secondResult;
        if (secondResult == null) _response(secondDialog, !allowFirst)();
        await tester.pumpAndSettle();
        final actualSecond = await second;
        await tester.pumpWidget(const SizedBox.shrink());
        expect(prematurelyAnswered, isNull);
        expect(actualSecond, !allowFirst);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an externally dismissed permission cannot grant a later request',
    (tester) async {
      await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('en')),
      );
      final state = _State();
      await tester.pumpWidget(
        LazerApp(state: state, audio: _Audio(), media: _Media()),
      );
      await tester.pumpAndSettle();
      final request = state.pluginManager.onPermissionRequest!;
      final plugin = _Plugin();
      final first = request(plugin, 'data.library');
      bool? secondResult;
      final second = request(plugin, 'data.profile').then((value) {
        secondResult = value;
        return value;
      });
      await tester.pumpAndSettle();
      final firstContext = tester.element(find.byType(AlertDialog));
      final staleAllow = _response(
        tester.widget<AlertDialog>(find.byType(AlertDialog)),
        true,
      );
      Navigator.of(firstContext).pop(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(await first, isFalse);
      expect(firstContext.mounted, isTrue);
      staleAllow();
      await tester.pump();
      expect(secondResult, isNull);
      final secondDialog = tester
          .widgetList<AlertDialog>(
            find.byType(AlertDialog, skipOffstage: false),
          )
          .last;
      _response(secondDialog, false)();
      await tester.pumpAndSettle();
      expect(await second, isFalse);
      expect(firstContext.mounted, isFalse);
      staleAllow();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
