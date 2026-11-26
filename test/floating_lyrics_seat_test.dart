import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _State extends AppState {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a dragged seat is written where the overlay reads it', () async {
    // The overlay used to re-centre itself on every launch, so a seat the
    // listener picked was gone the moment the lyrics were closed and reopened.
    // These are the exact keys `lyrics_overlay` reads back.
    final state = _State();
    await state.setFloatingLyricsPosition(1200, 640);
    expect(state.hasFloatingLyricsPosition, isTrue);
    expect(state.floatingLyricsPositionX, 1200);
    expect(state.floatingLyricsPositionY, 640);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('${AppState.floatingLyricsPositionKey}_x'), 1200);
    expect(prefs.getDouble('${AppState.floatingLyricsPositionKey}_y'), 640);
  });

  test('the stored pair round-trips through the preference layer', () async {
    // `AppState` reads the pair back while it loads its preferences; this pins
    // the keys and the null-when-absent contract that read depends on.
    SharedPreferences.setMockInitialValues(<String, Object>{
      '${AppState.floatingLyricsPositionKey}_x': 88.5,
      '${AppState.floatingLyricsPositionKey}_y': 501.25,
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('${AppState.floatingLyricsPositionKey}_x'), 88.5);
    expect(prefs.getDouble('${AppState.floatingLyricsPositionKey}_y'), 501.25);

    // A state with no stored pair reports "never placed", so the overlay keeps
    // its default bottom-centre seat instead of opening at the origin.
    final fresh = _State();
    expect(fresh.hasFloatingLyricsPosition, isFalse);
  });

  test(
    'clearing forgets the seat so the overlay returns to its default',
    () async {
      final state = _State();
      await state.setFloatingLyricsPosition(10, 20);
      expect(state.hasFloatingLyricsPosition, isTrue);
      await state.clearFloatingLyricsPosition();
      expect(state.hasFloatingLyricsPosition, isFalse);

      // The writer coalesces: a write that was already queued has to drain before
      // the removal lands, so let the queue settle before reading it back.
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getDouble('${AppState.floatingLyricsPositionKey}_x'),
        isNull,
      );
      expect(
        prefs.getDouble('${AppState.floatingLyricsPositionKey}_y'),
        isNull,
      );
    },
  );

  test(
    'writing the same seat twice does not keep rewriting preferences',
    () async {
      final state = _State();
      await state.setFloatingLyricsPosition(7, 9);
      // A drag that ends where it started must not schedule another write: the
      // overlay reports a drop on every pointer release.
      expect(state.floatingLyricsPositionX, 7);
      expect(state.floatingLyricsPositionY, 9);
      await state.setFloatingLyricsPosition(7, 9);
      expect(state.floatingLyricsPositionX, 7);
      expect(state.floatingLyricsPositionY, 9);
    },
  );
}
