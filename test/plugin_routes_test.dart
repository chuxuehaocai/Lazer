import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_market.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/plugin_manager_page.dart';
import 'package:lazer_nextgen/ui/plugin_market_page.dart';
import 'package:lazer_nextgen/widgets/shared_browse_background.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final marketPage in [false, true]) {
      testWidgets(
        '${platform.name} ${marketPage ? 'market' : 'manager'} never overlaps preceding page during entrance or return',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final root = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('plugin-route-'),
          ))!;
          final manager = PluginManager(rootDirectory: root);
          final state = AppState(pluginManager: manager);
          final market = PluginMarket(
            manager,
            client: MockClient(
              (_) async =>
                  http.Response('{"schemaVersion":1,"plugins":[]}', 200),
            ),
          );
          addTearDown(() async {
            market.dispose();
            state.dispose();
            await tester.runAsync(() => root.delete(recursive: true));
          });
          await tester.runAsync(manager.restore);
          final nav = GlobalKey<NavigatorState>();
          const marker = ValueKey('incoming-plugin-page');
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: nav,
              theme: buildAppleTheme().copyWith(platform: platform),
              builder: (_, child) => BrowseBackgroundScope(child: child!),
              home: const Scaffold(
                backgroundColor: Colors.transparent,
                body: Text('Previous settings'),
              ),
            ),
          );
          nav.currentState!.push(
            ApplePageRoute<void>(
              builder: (_) => KeyedSubtree(
                key: marker,
                child: marketPage
                    ? PluginMarketView(state: state, market: market)
                    : PluginManagerView(state: state),
              ),
            ),
          );
          await tester.pump();
          double opacity(Finder target) => tester
              .widgetList<FadeTransition>(
                find.ancestor(
                  of: target,
                  matching: find.byType(FadeTransition, skipOffstage: false),
                ),
              )
              .fold(1, (value, fade) => value * fade.opacity.value);
          Future<void> frames() async {
            for (var frame = 0; frame < 65; frame++) {
              final previous = find.text(
                'Previous settings',
                skipOffstage: false,
              );
              final incoming = find.byKey(marker, skipOffstage: false);
              if (previous.evaluate().isNotEmpty &&
                  incoming.evaluate().isNotEmpty) {
                expect(
                  opacity(previous) * opacity(incoming),
                  0,
                  reason: 'route controls must fade through without blending',
                );
              }
              await tester.pump(const Duration(milliseconds: 16));
            }
          }

          await frames();
          expect(tester.takeException(), isNull);
          nav.currentState!.pop();
          await tester.pump();
          await frames();
          expect(find.byKey(marker), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
