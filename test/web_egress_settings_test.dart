import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/plugins/web_plugin_http_proxy.dart';
import 'package:lazer_nextgen/ui/web_egress_settings.dart';
import 'package:lazer_nextgen/utils/system_http.dart';
import 'package:lazer_nextgen/utils/web_egress_preferences.dart';
import 'package:lazer_nextgen/widgets/settings_choice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to China and ignores invalid persisted countries', () async {
    final preferences = await SharedPreferences.getInstance();
    final settings = WebEgressPreferences();
    addTearDown(settings.dispose);
    settings.initFromPreferences(preferences);
    expect(settings.country, WebEgressCountry.cn);
    await preferences.setString(WebEgressPreferences.preferenceKey, 'invalid');
    settings.initFromPreferences(preferences);
    expect(settings.country, WebEgressCountry.cn);
  });

  test(
    'persists separately from native proxy and restores the last choice',
    () async {
      SharedPreferences.setMockInitialValues({
        SystemHttpProxy.prefKeyMode: 'custom',
      });
      final settings = WebEgressPreferences();
      final restored = WebEgressPreferences();
      addTearDown(settings.dispose);
      addTearDown(restored.dispose);
      await Future.wait([
        settings.setCountry(WebEgressCountry.jp),
        settings.setCountry(WebEgressCountry.de),
      ]);
      final preferences = await SharedPreferences.getInstance();
      restored.initFromPreferences(preferences);
      expect(restored.country, WebEgressCountry.de);
      expect(preferences.getString(SystemHttpProxy.prefKeyMode), 'custom');
    },
  );

  test(
    'every request uses the current host choice and manifest domains',
    () async {
      final settings = WebEgressPreferences();
      addTearDown(settings.dispose);
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        expect(request.url.path, '/api/plugin-http');
        expect(request.headers['content-type'], 'application/json');
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'status': 200,
            'headers': {'set-cookie': 'session=test'},
            'body': 'result',
          }),
          200,
        );
      });
      addTearDown(client.close);
      Future<Map<String, dynamic>> send() => sendWebPluginHttpRequest(
        client: client,
        endpoint: Uri.parse('https://player.example/api/plugin-http'),
        preferences: settings,
        domains: ['music.example'],
        spec: {
          'url': 'https://music.example/search',
          'egressCountry': 'US',
          'domains': ['other.example'],
        },
      );
      final first = await send();
      expect(first['body'], 'result');
      expect((first['headers'] as Map)['set-cookie'], 'session=test');
      await settings.setCountry(WebEgressCountry.jp);
      await send();
      expect(requests.map((r) => r['egressCountry']), ['CN', 'JP']);
      for (final request in requests) {
        expect(request['domains'], ['music.example']);
        expect(request['method'], 'GET');
      }
    },
  );

  test('proxy errors and malformed replies fail clearly', () async {
    for (final response in [
      http.Response('{}', 400),
      http.Response('[]', 200),
    ]) {
      final client = MockClient((_) async => response);
      addTearDown(client.close);
      await expectLater(
        sendWebPluginHttpRequest(
          client: client,
          endpoint: Uri.parse('https://player.example/api/plugin-http'),
          spec: {'url': 'https://music.example'},
          domains: ['music.example'],
        ),
        throwsFormatException,
      );
    }
  });

  testWidgets(
    'country selector changes and persists without restarting plugins',
    (tester) async {
      final settings = WebEgressPreferences();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WebEgressSettingsSection(preferences: settings)),
        ),
      );
      final selector = find.byKey(const ValueKey('web-egress-country'));
      final control = tester.widget<SettingsChoice<WebEgressCountry>>(selector);
      expect(control.value, WebEgressCountry.cn);
      expect(control.items.length, 16);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('日本').last);
      await tester.pumpAndSettle();
      expect(settings.country, WebEgressCountry.jp);
      expect(
        (await SharedPreferences.getInstance()).getString(
          WebEgressPreferences.preferenceKey,
        ),
        'JP',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
