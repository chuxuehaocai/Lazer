import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_autoscan.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/local/local_music_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryLibrary extends LocalLibrary {
  _MemoryLibrary([List<LocalTrack> initial = const <LocalTrack>[]])
    : _entries = List<LocalTrack>.of(initial);

  final List<LocalTrack> _entries;
  final List<String> roots = <String>[];
  int refreshes = 0;

  @override
  List<LocalTrack> get tracks => List<LocalTrack>.unmodifiable(_entries);

  @override
  Future<void> addScanRoot(String path) async => roots.add(path);

  @override
  Future<void> addTracks(Iterable<LocalTrack> entries) async =>
      _entries.addAll(entries);

  @override
  Future<void> refreshMissing() async => refreshes++;
}

class _FakeScanner extends LocalMusicScanner {
  _FakeScanner(this.root, [this.result = const LocalScanResult(tracks: [])]);

  final Directory root;
  final LocalScanResult result;
  int scans = 0;

  @override
  Future<Directory?> defaultRoot() async => root;

  @override
  Future<LocalScanResult> scan(
    Directory root, {
    Iterable<LocalTrack> existing = const <LocalTrack>[],
    bool Function()? isCanceled,
    void Function(int found, String current)? onProgress,
  }) async {
    scans++;
    return result;
  }
}

LocalTrack _track(String path) => LocalTrack(
  track: Track(
    id: localTrackIdForPath(path),
    title: path.split(Platform.pathSeparator).last,
    artist: 'Test',
    album: 'Test',
    duration: const Duration(seconds: 3),
    coverSeed: 7,
  ),
  path: path,
  source: LocalTrackSource.scan,
  modifiedAt: DateTime(2026, 1, 1),
  addedAt: DateTime(2026, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('local_autoscan_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('scans the music folder once and merges what it finds', () async {
    final library = _MemoryLibrary();
    final scanner = _FakeScanner(
      root,
      LocalScanResult(tracks: <LocalTrack>[_track('${root.path}/a.mp3')]),
    );

    final result = await autoScanLocalMusicOnce(
      library,
      scanner: scanner,
      root: root,
    );

    expect(result, isNotNull);
    expect(result!.tracks, hasLength(1));
    expect(scanner.scans, 1);
    expect(library.tracks, hasLength(1));
    expect(library.roots, <String>[root.path]);
    expect(library.refreshes, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(localAutoScanKey), isTrue);

    // The next launch must not walk the folder again.
    expect(
      await autoScanLocalMusicOnce(library, scanner: scanner, root: root),
      isNull,
    );
    expect(scanner.scans, 1);
  });

  test('leaves a library that already holds music alone', () async {
    final library = _MemoryLibrary(<LocalTrack>[_track('${root.path}/a.mp3')]);
    final scanner = _FakeScanner(root);

    expect(
      await autoScanLocalMusicOnce(library, scanner: scanner, root: root),
      isNull,
    );
    expect(scanner.scans, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(localAutoScanKey), isTrue);
  });

  test('records an empty result instead of rescanning every launch', () async {
    final library = _MemoryLibrary();
    final scanner = _FakeScanner(root);

    final result = await autoScanLocalMusicOnce(
      library,
      scanner: scanner,
      root: root,
    );

    expect(result, isNotNull);
    expect(result!.tracks, isEmpty);
    expect(library.roots, isEmpty);
    expect(
      await autoScanLocalMusicOnce(library, scanner: scanner, root: root),
      isNull,
    );
    expect(scanner.scans, 1);
  });

  test('skips a folder that is not there', () async {
    final library = _MemoryLibrary();
    final missing = Directory('${root.path}/nope');
    final scanner = _FakeScanner(missing);

    expect(await autoScanLocalMusicOnce(library, scanner: scanner), isNull);
    expect(scanner.scans, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(localAutoScanKey), isTrue);
  });
}
