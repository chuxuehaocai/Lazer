import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/widgets.dart';

void main() {
  testWidgets('track row hover uses the same surface as current playback', (
    tester,
  ) async {
    const track = Track(
      id: 'track-1',
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
      coverSeed: 1,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 100,
            child: AppTrackRow(
              track: track,
              index: 0,
              current: true,
              onTap: _noop,
            ),
          ),
        ),
      ),
    );

    final inkWell = tester.widget<InkWell>(find.byType(InkWell).first);
    expect(
      inkWell.overlayColor?.resolve(<WidgetState>{WidgetState.hovered}),
      Colors.transparent,
    );
    expect(
      inkWell.overlayColor?.resolve(<WidgetState>{WidgetState.pressed}),
      Colors.transparent,
    );
  });
}

void _noop() {}
