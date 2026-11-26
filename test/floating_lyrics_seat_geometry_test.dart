import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_seat.dart';
import 'package:screen_retriever/screen_retriever.dart';

const Size _window = Size(720, 180);

Display _display({
  required Offset at,
  Size size = const Size(1920, 1080),
  Size? visible,
}) => Display(
  id: '${at.dx}x${at.dy}',
  size: size,
  visiblePosition: at,
  visibleSize: visible ?? size,
);

void main() {
  test(
    'a seat that still fits the desktop is left exactly where it was',
    () async {
      // The whole point of restoring the seat: no drifting by a pixel, no
      // re-centring. Reachable means untouched.
      const Offset seat = Offset(1200, 640);
      final Offset placed = await reachableFloatingSeat(
        seat,
        _window,
        displays: () async => <Display>[_display(at: Offset.zero)],
      );
      expect(placed, seat);
    },
  );

  test(
    'a seat on a display that is gone comes back to the one that is left',
    () async {
      // The laptop was undocked: 3000 px to the right of a 1920 px desktop used to
      // reopen the overlay entirely off-screen, with no title bar to drag back.
      final Offset placed = await reachableFloatingSeat(
        const Offset(3000, 400),
        _window,
        displays: () async => <Display>[_display(at: Offset.zero)],
      );
      expect(placed.dx, 1920 - _window.width);
      expect(placed.dy, 400, reason: 'the vertical position was still fine');
    },
  );

  test(
    'a second display keeps the seat on its own side of the desktop',
    () async {
      // Both monitors present: a seat on the right one must not be pulled left to
      // the primary, or the listener's layout is scrambled on every launch.
      const Offset seat = Offset(2200, 300);
      final Offset placed = await reachableFloatingSeat(
        seat,
        _window,
        displays: () async => <Display>[
          _display(at: Offset.zero),
          _display(at: const Offset(1920, 0)),
        ],
      );
      expect(placed, seat);
    },
  );

  test(
    'a seat left behind by a removed second display returns to the primary',
    () async {
      // The right monitor was unplugged after the lyrics were parked on it.
      final Offset placed = await reachableFloatingSeat(
        const Offset(2600, 300),
        _window,
        displays: () async => <Display>[_display(at: Offset.zero)],
      );
      expect(placed.dx, lessThanOrEqualTo(1920 - _window.width));
      expect(placed.dx, greaterThanOrEqualTo(0));
    },
  );

  test('a negative seat is pulled back onto the display', () async {
    // Displays to the left of the primary report negative origins; a stored seat
    // can end up negative once that monitor is gone.
    final Offset placed = await reachableFloatingSeat(
      const Offset(-400, -50),
      _window,
      displays: () async => <Display>[_display(at: Offset.zero)],
    );
    expect(placed.dx, 0);
    expect(placed.dy, 0);
  });

  test('a window larger than the display is pinned to its origin', () async {
    // Clamping to `end - extent` would push a bigger-than-screen window off the
    // opposite edge; the start edge is the only one that can be honoured.
    final Offset placed = await reachableFloatingSeat(
      const Offset(500, 500),
      const Size(2400, 1400),
      displays: () async => <Display>[_display(at: Offset.zero)],
    );
    expect(placed, Offset.zero);
  });

  test('a half-off-screen window is pulled fully into view', () async {
    // Nothing holds the whole window, so it is the window that moves.
    final Offset placed = await reachableFloatingSeat(
      const Offset(1800, 1000),
      _window,
      displays: () async => <Display>[_display(at: Offset.zero)],
    );
    expect(placed.dx, 1920 - _window.width);
    expect(placed.dy, 1080 - _window.height);
  });

  test('a display without a reported origin contributes nothing', () async {
    // Guessing a rectangle is how a window ends up "placed" off-screen; the seat
    // is kept instead of being moved to a position nobody verified.
    const Offset seat = Offset(50, 60);
    final Offset placed = await reachableFloatingSeat(
      seat,
      _window,
      displays: () async => <Display>[
        const Display(
          id: 'no-origin',
          size: Size(1920, 1080),
          visibleSize: Size(1920, 1080),
        ),
      ],
    );
    expect(placed, seat);
  });

  test('an empty display list keeps the seat', () async {
    const Offset seat = Offset(50, 60);
    expect(
      await reachableFloatingSeat(
        seat,
        _window,
        displays: () async => const <Display>[],
      ),
      seat,
    );
  });

  test('a failing display probe keeps the seat', () async {
    // Tests and unsupported platforms have no channel. The stored seat still
    // beats re-centring, which is the behaviour this replaced.
    const Offset seat = Offset(50, 60);
    expect(
      await reachableFloatingSeat(
        seat,
        _window,
        displays: () async => throw UnimplementedError(),
      ),
      seat,
    );
  });

  test(
    'a taskbar-inset visible area is what the seat is measured against',
    () async {
      // Windows reports the work area (minus the taskbar) as the visible rect; a
      // seat under it must be lifted, because that is where the overlay would be
      // covered.
      final Offset placed = await reachableFloatingSeat(
        const Offset(100, 1070),
        _window,
        displays: () async => <Display>[
          _display(at: Offset.zero, visible: const Size(1920, 1040)),
        ],
      );
      expect(placed.dy, 1040 - _window.height);
    },
  );
}
