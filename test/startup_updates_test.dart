import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_market.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/updates/update_checker.dart';

Uint8List _package(String id, String version) {
  final archive = Archive();
  final files = <String, String>{
    'manifest.json': jsonEncode(<String, Object?>{
      'id': id,
      'provider': 'fixture',
      'name': id,
      'version': version,
      'apiVersion': 1,
    }),
    'main.lua': 'return {call=function(op,args) return {} end}',
  };
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, Object?> _entry(
  String id,
  String version,
  Uint8List bytes,
) => <String, Object?>{
  'id': id,
  'version': version,
  'name': <String, String>{'zh-CN': id, 'en': id},
  'summary': <String, String>{'zh-CN': '测试插件更新', 'en': 'Fixture plugin update'},
  'author': 'Fixture',
  'download': '$id-$version.zip',
  'sha256': sha256.convert(bytes).toString(),
  'platforms': <String>['windows', 'linux', 'macos', 'android', 'ios'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('startup prompts for each plugin and applies user choices', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('startup-plugin-updates-'),
    ))!;
    final manager = PluginManager(rootDirectory: root);
    var clientChecks = 0;
    final alphaOld = _package('fixture.alpha', '1.0.0');
    final betaOld = _package('fixture.beta', '1.0.0');
    await tester.runAsync(() async {
      await manager.importZip(alphaOld);
      await manager.importZip(betaOld);
    });
    final alphaNew = _package('fixture.alpha', '1.1.0');
    final betaNew = _package('fixture.beta', '1.1.0');
    final market = PluginMarket(
      manager,
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('.json')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'plugins': <Map<String, Object?>>[
                _entry('fixture.alpha', '1.1.0', alphaNew),
                _entry('fixture.beta', '1.1.0', betaNew),
              ],
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response.bytes(
          request.url.path.endsWith('fixture.alpha-1.1.0.zip')
              ? alphaNew
              : betaNew,
          200,
        );
      }),
    );
    await tester.runAsync(market.restore);
    final state = AppState(
      pluginManager: manager,
      pluginMarket: market,
      updateChecker: UpdateChecker(
        fetch: (_) async {
          clientChecks++;
          return http.Response('[]', 200);
        },
      ),
    );
    addTearDown(() async {
      market.dispose();
      state.dispose();
      await root.delete(recursive: true);
    });
    expect(state.pluginMarket, same(market));
    expect(manager.plugins, hasLength(2));
    expect(market.plugins, hasLength(2));
    expect(market.error, isNull);
    Future<void> pumpUntil(Finder finder) async {
      for (var frame = 0; frame < 60; frame++) {
        if (finder.evaluate().isNotEmpty) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> pumpUntilGone(Finder finder) async {
      for (var frame = 0; frame < 60; frame++) {
        if (finder.evaluate().isEmpty) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: AppShell(state: state, autoCheckUpdates: true),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    await pumpUntil(find.text('发现插件更新'));

    expect(find.text('发现插件更新'), findsOneWidget);
    expect(find.text('fixture.alpha'), findsOneWidget);
    expect(clientChecks, 1);
    await tester.tap(find.text('跳过此版本'));
    await pumpUntil(find.text('fixture.beta'));
    await tester.pumpAndSettle();

    expect(find.text('fixture.beta'), findsOneWidget);
    await tester.tap(find.text('更新'));
    await pumpUntilGone(find.text('发现插件更新'));
    await tester.pumpAndSettle();

    expect(find.text('发现插件更新'), findsNothing);
    expect(
      manager.plugins
          .firstWhere((plugin) => plugin.manifest.id == 'fixture.alpha')
          .manifest
          .version,
      '1.0.0',
    );
    expect(
      manager.plugins
          .firstWhere((plugin) => plugin.manifest.id == 'fixture.beta')
          .manifest
          .version,
      '1.1.0',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('lazer_skipped_plugin_updates')!)
          as Map<String, dynamic>,
      <String, dynamic>{'fixture.alpha': '1.1.0'},
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
