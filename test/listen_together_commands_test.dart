import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/listen_together_commands.dart';

void main() {
  test('member sequences do not hide another member starting at one', () {
    final clock = RoomCommandClock();
    expect(
      clock.accept({'commandType': 'PLAY', 'userId': 'a', 'clientSeq': 90}),
      isTrue,
    );
    expect(
      clock.accept({'commandType': 'PAUSE', 'userId': 'b', 'clientSeq': 1}),
      isTrue,
    );
    expect(
      clock.accept({'commandType': 'PLAY', 'userId': 'a', 'clientSeq': 89}),
      isFalse,
    );
    expect(
      clock.accept({'commandType': 'PLAY', 'userId': 'b', 'clientSeq': 2}),
      isTrue,
    );
  });

  test('server sequence takes precedence and room replacement resets it', () {
    final clock = RoomCommandClock();
    expect(
      clock.accept({'commandType': 'PLAY', 'serverSeq': 20, 'clientSeq': 99}),
      isTrue,
    );
    expect(
      clock.accept({'commandType': 'PAUSE', 'serverSeq': 19, 'clientSeq': 100}),
      isFalse,
    );
    clock.clear();
    expect(clock.accept({'commandType': 'PAUSE', 'serverSeq': 1}), isTrue);
  });

  test('repeated legacy commands do not seek backwards every heartbeat', () {
    final clock = RoomCommandClock();
    final command = {
      'commandType': 'PLAY',
      'targetSongId': 'song',
      'progress': 1000,
    };
    expect(clock.accept(command), isTrue);
    expect(clock.accept(Map<String, dynamic>.of(command)), isFalse);
    expect(clock.accept({...command, 'progress': 0}), isTrue);
    expect(clock.accept({'commandType': 'UNKNOWN', 'serverSeq': 999}), isFalse);
    expect(clock.accept({'commandType': 'PAUSE', 'serverSeq': 1}), isTrue);
  });
}
