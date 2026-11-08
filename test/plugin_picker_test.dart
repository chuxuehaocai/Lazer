import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/plugin_manager_page.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '${platform.name} ZIP picker is cancellable, guards repeat clicks and recovers from errors',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('plugin-picker-'),
        ))!;
        final manager = PluginManager(rootDirectory: root);
        final state = AppState(pluginManager: manager);
        await tester.runAsync(manager.restore);
        addTearDown(() async {
          state.dispose();
          await tester.runAsync(() => root.delete(recursive: true));
        });
        const channel = MethodChannel('plugins.flutter.io/file_selector');
        var requests = 0;
        var pending = Completer<Object?>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            requests++;
            expect(call.method, 'openFile');
            final types =
                ((call.arguments as Map)['acceptedTypeGroups'] as List).single
                    as Map;
            expect(types['extensions'], ['zip']);
            expect(types['mimeTypes'], contains('application/zip'));
            expect(
              types['uniformTypeIdentifiers'],
              contains('public.zip-archive'),
            );
            return pending.future;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme().copyWith(platform: platform),
            home: PluginManagerPage(state: state),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('导入 ZIP'));
        await tester.pump();
        expect(find.text('正在导入…'), findsOneWidget);
        expect(requests, 1);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        pending.complete(null);
        await tester.pumpAndSettle();
        expect(find.text('导入 ZIP'), findsOneWidget);
        expect(manager.plugins, isEmpty);
        pending = Completer<Object?>();
        await tester.tap(find.text('导入 ZIP'));
        await tester.pump();
        pending.completeError(
          PlatformException(
            code: 'picker_unavailable',
            message: 'Picker failed',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Picker failed'), findsOneWidget);
        expect(find.text('导入 ZIP'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
