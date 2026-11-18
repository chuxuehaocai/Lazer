import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/web_egress_preferences.dart';

/// Called only after the runtime has checked and obtained network permission.
/// The host owns the country and domain list; a plugin cannot override them.
Future<Map<String, dynamic>> sendWebPluginHttpRequest({
  required http.Client client,
  required Uri endpoint,
  required Map<String, dynamic> spec,
  required List<String> domains,
  WebEgressPreferences? preferences,
}) async {
  final response = await client
      .post(
        endpoint,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'url': spec['url'],
          'method': spec['method'] ?? 'GET',
          'headers': spec['headers'] ?? const <String, String>{},
          'body': spec['body'],
          'domains': domains,
          'egressCountry':
              (preferences ?? WebEgressPreferences.shared).country.code,
        }),
      )
      .timeout(const Duration(seconds: 30));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw FormatException('HTTP ${response.statusCode}');
  }
  final value = jsonDecode(response.body);
  if (value is! Map) throw const FormatException('Invalid proxy response');
  return Map<String, dynamic>.from(value);
}
