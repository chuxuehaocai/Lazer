import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/utils/media_requests.dart';

void main() {
  tearDown(() {
    MediaRequestRules.remove('evil');
    MediaRequestRules.remove('plugin');
  });

  test('a rule only applies to hosts the plugin declared', () {
    MediaRequestRules.register('evil', <Map<String, dynamic>>[
      <String, dynamic>{
        'host': 'cdn.other.example',
        'headers': <String, String>{'Referer': 'https://evil.example'},
      },
    ], permittedDomains: <String>['cdn.evil.example']);
    expect(
      MediaRequestRules.rule(Uri.parse('https://cdn.other.example/a.jpg')),
      isNull,
    );
    expect(
      MediaRequestRules.headers('https://cdn.other.example/a.jpg')['Referer'],
      isNull,
    );
  });

  test('credential headers, wildcard suffixes and foreign fallbacks are dropped',
      () {
    MediaRequestRules.register('plugin', <Map<String, dynamic>>[
      <String, dynamic>{'host': '*.com'},
      <String, dynamic>{
        'host': 'cdn.good.example',
        'headers': <String, String>{
          'Cookie': 'sid=secret',
          'Authorization': 'Bearer secret',
          'X-Cdn-Key': 'public',
        },
        'fallbackHosts': <String>['cdn.other.example', 'cdn.good.example'],
        'artworkResize': <String, dynamic>{
          'parameter': 'size',
          'value': '{size}',
        },
      },
    ], permittedDomains: <String>['*.com', '*.good.example']);
    final Map<String, dynamic>? rule = MediaRequestRules.rule(
      Uri.parse('https://cdn.good.example/a.jpg'),
    );
    expect(rule, isNotNull);
    expect(
      (rule!['headers'] as Map).keys,
      <String>['x-cdn-key'],
      reason: 'a plugin must not inject credentials into a media request',
    );
    expect(
      rule['fallbackHosts'],
      <String>['cdn.good.example'],
      reason: 'a fallback host is still a host the plugin has to be allowed',
    );
    expect(
      MediaRequestRules.rule(Uri.parse('https://anything.com/a.jpg')),
      isNull,
      reason: 'a public-suffix wildcard is not a host scope',
    );
  });
}
