import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/utils/system_http.dart';

void main() {
  group('system proxy parsing', () {
    test('reads a bare host and port', () {
      final proxy = SystemHttpProxy.parse('127.0.0.1:7897');
      expect(proxy?.host, '127.0.0.1');
      expect(proxy?.port, 7897);
      expect(proxy?.rules, 'PROXY 127.0.0.1:7897');
    });

    test('reads the scheme the registry stores', () {
      expect(
        SystemHttpProxy.parse('http://proxy.local:8080')?.rules,
        'PROXY proxy.local:8080',
      );
      expect(
        SystemHttpProxy.parse('socks5://127.0.0.1:7891')?.rules,
        'SOCKS 127.0.0.1:7891',
      );
    });

    test('drops credentials', () {
      final proxy = SystemHttpProxy.parse('user:secret@10.0.0.2:3128');
      expect(proxy?.host, '10.0.0.2');
      expect(proxy?.port, 3128);
    });

    test('prefers the https entry of a combined value', () {
      final proxy = SystemHttpProxy.parse(
        'http=127.0.0.1:7897;https=127.0.0.1:7898',
      );
      expect(proxy?.port, 7898);
    });

    test('rejects values that cannot be a proxy', () {
      for (final value in <String>['', '  ', 'proxy.local', 'ftp://host:21']) {
        expect(SystemHttpProxy.parse(value), isNull, reason: value);
      }
      expect(SystemHttpProxy.parse('host:0'), isNull);
      expect(SystemHttpProxy.parse('host:70000'), isNull);
    });
  });
}
