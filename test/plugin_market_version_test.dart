import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/ui/plugin_market_page.dart';

void main() {
  group('plugin market versions', () {
    test('a newer market build offers an update', () {
      expect(pluginUpdateAvailable(candidate: '1.4.0', current: '1.3.5'), isTrue);
      expect(pluginUpdateAvailable(candidate: 'v1.4.0', current: 'v1.3.5'), isTrue);
    });

    test('the installed build offers nothing', () {
      expect(
        pluginUpdateAvailable(candidate: '1.3.5', current: '1.3.5'),
        isFalse,
      );
      expect(
        pluginUpdateAvailable(candidate: '1.3.4', current: '1.3.5'),
        isFalse,
      );
    });

    // The row compared two force-unwrapped parses. A manifest may spell its
    // version in any way, and one unparseable value blanked the whole market as
    // soon as that plugin was installed.
    test('an unparseable version reports no update instead of throwing', () {
      expect(
        pluginUpdateAvailable(candidate: '1.4.0', current: '1.0.0.0'),
        isFalse,
      );
      expect(
        pluginUpdateAvailable(candidate: 'nightly', current: '1.0.0'),
        isFalse,
      );
      expect(
        pluginUpdateAvailable(candidate: '1.0.0', current: ''),
        isFalse,
      );
    });
  });
}
