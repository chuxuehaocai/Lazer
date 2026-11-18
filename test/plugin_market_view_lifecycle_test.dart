import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_market.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/ui/plugin_market_page.dart';

void main() {
  testWidgets(
    'changing market source binds the visible catalogue to its owner',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = PluginManager();
      final state = AppState(pluginManager: manager);
      var firstRequests = 0;
      var secondRequests = 0;
      final first = PluginMarket(
        manager,
        client: MockClient((_) async {
          firstRequests++;
          return http.Response(
            jsonEncode({'schemaVersion': 1, 'plugins': []}),
            200,
          );
        }),
      );
      final second = PluginMarket(
        manager,
        client: MockClient((_) async {
          secondRequests++;
          return http.Response(
            jsonEncode({'schemaVersion': 1, 'plugins': []}),
            200,
          );
        }),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(state.dispose);
      await tester.runAsync(() async {
        await first.restore();
        await second.restore();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PluginMarketView(state: state, market: first),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: PluginMarketView(state: state, market: second),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final refreshed = Completer<void>();
        void changed() {
          if (!second.loading && !refreshed.isCompleted) refreshed.complete();
        }

        second.addListener(changed);
        await tester.tap(find.byTooltip('刷新'));
        await refreshed.future.timeout(const Duration(seconds: 5));
        second.removeListener(changed);
      });
      await tester.pumpAndSettle();
      expect(firstRequests, 1);
      expect(secondRequests, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reopening the market reuses the app catalogue and HTTP client', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    final manager = PluginManager();
    final market = PluginMarket(
      manager,
      client: MockClient((_) async {
        requests++;
        return http.Response(
          jsonEncode({'schemaVersion': 1, 'plugins': []}),
          200,
        );
      }),
    );
    final state = AppState(pluginManager: manager, pluginMarket: market);
    addTearDown(market.dispose);
    addTearDown(state.dispose);
    await tester.runAsync(market.restore);
    for (var visit = 0; visit < 3; visit++) {
      await tester.pumpWidget(
        MaterialApp(home: PluginMarketView(state: state)),
      );
      await tester.pumpAndSettle();
      expect(find.text('插件源暂时没有可用插件'), findsOneWidget);
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(tester.takeException(), isNull);
  });
}
