import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/settings_detail.dart';
import 'package:lazer_nextgen/widgets/window_chrome_surface.dart';

double? recordedInset;
double? recordedBodyTop;

class _ProbeBody extends StatelessWidget {
  const _ProbeBody();

  @override
  Widget build(BuildContext context) {
    recordedInset = SettingsDetailScaffold.topInsetOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        recordedBodyTop = box.maxHeight;
        return const SizedBox.expand(key: ValueKey<String>('probe-body'));
      },
    );
  }
}

void main() {
  testWidgets('a mobile subview floats its header over the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    recordedInset = null;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsDetailScaffold(
                    title: 'Fonts',
                    child: _ProbeBody(),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // No bar reserves the top of the page: the body owns the whole area and the
    // back button floats above it, exactly like the desktop capsule's row.
    final bodyTop = tester.getRect(find.byKey(const ValueKey('probe-body'))).top;
    expect(
      bodyTop,
      lessThan(16),
      reason: 'the body starts at the top edge, not below a reserved strip',
    );
    final back = tester.getRect(
      find.byKey(const ValueKey('settings-detail-back')),
    );
    expect(back.top, lessThan(16));

    // The body is told how much room those controls need, so its own first row
    // still starts below them while everything above can scroll underneath.
    expect(recordedInset, greaterThanOrEqualTo(kPageBackControlSize));
    expect(
      recordedInset,
      greaterThanOrEqualTo(back.height),
      reason: 'the inset clears the floating control',
    );
  });
}
