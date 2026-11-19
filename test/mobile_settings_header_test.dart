import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/settings_detail.dart';

const _bodyKey = ValueKey<String>('probe-body');

Widget _host() => MaterialApp(
  home: Builder(
    builder: (context) => Center(
      child: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const SettingsDetailScaffold(
              title: 'Fonts',
              headerTitle: true,
              child: SizedBox.expand(key: _bodyKey),
            ),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  testWidgets('a mobile subview keeps its header in a fixed strip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final back = tester.getRect(
      find.byKey(const ValueKey('settings-detail-back')),
    );
    final body = tester.getRect(find.byKey(_bodyKey));
    // The header owns a band above the page: the back control clears the top
    // edge by its own inset, and the body starts under it instead of sliding
    // beneath a floating control.
    expect(back.top, 8);
    expect(body.top, greaterThanOrEqualTo(back.bottom));
    expect(body.top, closeTo(56, .01));
    expect(find.text('Fonts').hitTestable(), findsOneWidget);

    // The strip already cleared the controls, so a page must not pad the same
    // band again.
    expect(
      SettingsDetailScaffold.topInsetOf(tester.element(find.byKey(_bodyKey))),
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a desktop route still floats its header over the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final back = tester.getRect(
      find.byKey(const ValueKey('settings-detail-back')),
    );
    final body = tester.getRect(find.byKey(_bodyKey));
    // A wide window has no capsule above it here, but it is still a desktop
    // presentation: the controls float and the body owns the whole page.
    expect(back.top, 0);
    expect(body.top, 0);
    expect(
      SettingsDetailScaffold.topInsetOf(tester.element(find.byKey(_bodyKey))),
      greaterThanOrEqualTo(back.height),
      reason: 'the body pads itself below the floating control',
    );
    expect(tester.takeException(), isNull);
  });
}
