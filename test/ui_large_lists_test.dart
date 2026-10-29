import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/local/local_music_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track track(int i) => Track(
  id: '$i',
  title: 'Song $i',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: i,
);

class QueueState extends AppState {
  final List<Track> entries = List<Track>.generate(1000, track);
  int reads = 0;
  @override
  List<Track> get queue {
    reads++;
    return List<Track>.unmodifiable(entries);
  }

  @override
  int get queueLength => entries.length;

  @override
  Track? get current => entries[500];
  @override
  int get queueIndex => 500;
  @override
  bool get playing => false;
}

class MissingLibrary extends LocalLibrary {
  int revision = 0;
  int reads = 0;
  final List<LocalTrack> entries = List<LocalTrack>.generate(
    1000,
    (i) => LocalTrack(
      track: track(i),
      path: '/missing/$i',
      source: LocalTrackSource.scan,
      modifiedAt: DateTime(2020),
      addedAt: DateTime(2020),
      missing: true,
    ),
  );
  @override
  List<LocalTrack> get tracks {
    reads++;
    return List<LocalTrack>.unmodifiable(entries);
  }

  @override
  int get tracksRevision => revision;
  void reportUnchanged() => notifyListeners();
  @override
  Future<void> remove(LocalTrack entry, {bool deleteFile = false}) async {
    entries.remove(entry);
    revision++;
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'queue takes one snapshot per build and opens at the current index',
    (tester) async {
      final state = QueueState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlaybackQueueView(state: state)),
        ),
      );
      await tester.pump();
      expect(state.reads, 1);
      expect(find.text('Song 500'), findsOneWidget);
      expect(find.text('Song 0'), findsNothing);
    },
  );
  testWidgets(
    'missing files are built lazily and can be removed after scrolling',
    (tester) async {
      final library = MissingLibrary();
      final state = AppState(localLibrary: library);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LocalMusicPage(state: state)),
        ),
      );
      await tester.pump();
      final int initialReads = library.reads;
      library.reportUnchanged();
      await tester.pump();
      expect(library.reads, initialReads);
      expect(find.text('Song 0'), findsOneWidget);
      expect(find.text('Song 999'), findsNothing);
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Song 999'), findsOneWidget);
      final tile = find.ancestor(
        of: find.text('Song 999'),
        matching: find.byType(AppleListTile),
      );
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(IconButton)),
      );
      await tester.pump();
      expect(library.entries.length, 999);
      expect(library.reads, greaterThan(initialReads));
      expect(library.entries.any((entry) => entry.id == '999'), isFalse);
    },
  );
}
