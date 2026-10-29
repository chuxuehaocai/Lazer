import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';

Track _track(String id, String title) => Track(
  id: id,
  title: title,
  artist: '音乐人',
  album: '专辑',
  duration: const Duration(minutes: 3),
  coverSeed: 0,
);

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-local-library-test-');
    support = Directory('${root.path}/support');
    documents = Directory('${root.path}/documents');
    await support.create(recursive: true);
    await documents.create(recursive: true);
  });
  tearDown(() async => root.delete(recursive: true));

  LocalLibrary create() => LocalLibrary(
    supportDirectory: () async => support,
    documentsDirectory: () async => documents,
  );

  Future<File> writeFile(String name, List<int> bytes) async {
    final File file = File('${documents.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  String native(String path) {
    String value = File(path).absolute.path;
    if (Platform.isWindows) value = value.replaceAll('/', '\\');
    return value;
  }

  test('round-trips entries through the manifest', () async {
    final File file = await writeFile('music/a.mp3', <int>[1, 2, 3]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('42', '曲目'),
        path: file.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.lossless,
        bytes: 3,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        addedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    ]);
    expect(library.count, 1);
    expect(library.tracks.single.track.localPath, native(file.path));

    final LocalLibrary reopened = create();
    await reopened.load();
    expect(reopened.count, 1);
    final LocalTrack entry = reopened.tracks.single;
    expect(entry.track.title, '曲目');
    expect(entry.path, native(file.path));
    expect(entry.quality, AudioQuality.lossless);
    expect(entry.source, LocalTrackSource.download);
    expect(entry.track.localPath, native(file.path));

    final String manifest = await File(
      '${support.path}/local_library.json',
    ).readAsString();
    expect(manifest, contains('documents:music/a.mp3'));
  });

  test(
    'large manifests restore track metadata and document-relative paths',
    () async {
      final records = <Map<String, dynamic>>[
        for (var i = 0; i < 500; i++)
          LocalTrack(
            track: _track('$i', 'Track $i'),
            path: 'documents:music/$i.mp3',
            source: LocalTrackSource.download,
            quality: AudioQuality.lossless,
            addedAt: DateTime.fromMillisecondsSinceEpoch(i),
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(i),
          ).toJson(),
      ];
      final manifest = File('${support.path}/local_library.json');
      await manifest.writeAsString(
        jsonEncode({
          'version': 1,
          'tracks': records,
          'scanRoots': [documents.path],
        }),
      );
      expect(await manifest.length(), greaterThan(65536));
      final library = LocalLibrary(
        supportDirectory: () async => support,
        documentsDirectory: () async => documents,
        fileExists: (_) async => true,
      );
      await library.load();
      expect(library.count, 500);
      expect(library.tracks.last.track.title, 'Track 499');
      expect(
        library.tracks.last.path,
        native('${documents.path}/music/499.mp3'),
      );
      expect(library.tracks.last.quality, AudioQuality.lossless);
      expect(library.scanRoots, [documents.path]);
      library.dispose();
    },
  );

  test(
    'disposing while a manifest load waits does not notify listeners',
    () async {
      await File('${support.path}/local_library.json').writeAsString(
        jsonEncode({'version': 1, 'tracks': [], 'scanRoots': []}),
      );
      final directoryReady = Completer<Directory>();
      final library = LocalLibrary(
        supportDirectory: () => directoryReady.future,
      );
      var notifications = 0;
      library.addListener(() => notifications++);
      final loading = library.load();
      library.dispose();
      directoryReady.complete(support);
      await loading;
      expect(notifications, 0);
    },
  );

  test('concurrent loads and imports wait for the stored manifest', () async {
    final saved = LocalTrack(
      track: _track('old', 'Old'),
      path: 'documents:old.mp3',
      source: LocalTrackSource.scan,
      addedAt: DateTime(2020),
      modifiedAt: DateTime(2020),
    );
    await File('${support.path}/local_library.json').writeAsString(
      jsonEncode({
        'version': 1,
        'tracks': [saved.toJson()],
        'scanRoots': [],
      }),
    );
    final resolving = Completer<void>();
    final release = Completer<void>();
    final library = LocalLibrary(
      supportDirectory: () async => support,
      documentsDirectory: () async {
        if (!resolving.isCompleted) resolving.complete();
        await release.future;
        return documents;
      },
      fileExists: (_) async => true,
    );
    final firstLoad = library.load();
    await resolving.future;
    final secondLoad = library.load();
    expect(identical(firstLoad, secondLoad), isTrue);
    final import = library.addTracks([
      LocalTrack(
        track: _track('new', 'New'),
        path: '${documents.path}/new.mp3',
        source: LocalTrackSource.scan,
        addedAt: DateTime(2021),
        modifiedAt: DateTime(2021),
      ),
    ]);
    release.complete();
    await Future.wait([firstLoad, secondLoad, import]);
    expect(library.tracks.map((entry) => entry.id), ['old', 'new']);
    final reopened = LocalLibrary(
      supportDirectory: () async => support,
      documentsDirectory: () async => documents,
      fileExists: (_) async => true,
    );
    await reopened.load();
    expect(reopened.tracks.map((entry) => entry.id), ['old', 'new']);
    library.dispose();
    reopened.dispose();
  });

  test('large concurrent updates persist the final manifest', () async {
    final library = LocalLibrary(
      supportDirectory: () async => support,
      documentsDirectory: () async => documents,
      fileExists: (_) async => true,
    );
    final entries = <LocalTrack>[
      for (var i = 0; i < 500; i++)
        LocalTrack(
          track: _track('$i', 'Track $i'),
          path: '${documents.path}/$i.mp3',
          source: LocalTrackSource.scan,
          modifiedAt: DateTime(2020),
          addedAt: DateTime(2020),
        ),
    ];
    await Future.wait([
      library.addTracks(entries),
      for (var i = 0; i < 20; i++)
        library.addScanRoot('${documents.path}/music-$i'),
    ]);
    final reopened = LocalLibrary(
      supportDirectory: () async => support,
      documentsDirectory: () async => documents,
      fileExists: (_) async => true,
    );
    await reopened.load();
    expect(reopened.count, 500);
    expect(reopened.tracks.last.track.title, 'Track 499');
    expect(reopened.scanRoots, [
      for (var i = 0; i < 20; i++) native('${documents.path}/music-$i'),
    ]);
    library.dispose();
    reopened.dispose();
  });

  test(
    'path lookup remains correct after replacement and index shifts',
    () async {
      LocalTrack entry(String name, String id) => LocalTrack(
        track: _track(id, id),
        path: '${documents.path}/$name.mp3',
        source: LocalTrackSource.scan,
        addedAt: DateTime(2020),
        modifiedAt: DateTime(2020),
      );
      final library = LocalLibrary(
        supportDirectory: () async => support,
        documentsDirectory: () async => documents,
        fileExists: (_) async => true,
      );
      await library.addTracks([entry('a', 'first'), entry('b', 'second')]);
      expect(library.entryForPath('${documents.path}/b.mp3')?.id, 'second');
      await library.remove(library.entryForPath('${documents.path}/a.mp3')!);
      await library.addTracks([entry('b', 'replacement'), entry('c', 'third')]);
      expect(library.count, 2);
      expect(
        library.entryForPath('${documents.path}/b.mp3')?.id,
        'replacement',
      );
      expect(library.entryForPath('${documents.path}/c.mp3')?.id, 'third');
      library.dispose();
    },
  );

  test('flags files that disappeared without dropping the entry', () async {
    final File file = await writeFile('missing.mp3', <int>[1]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('7', '走了'),
        path: file.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    await file.delete();
    final revision = library.tracksRevision;
    await library.refreshMissing();
    expect(library.tracks.single.missing, isTrue);
    expect(library.tracksRevision, greaterThan(revision));
    expect(await library.localFileFor(_track('7', '走了')), isNull);
    await library.clearMissing();
    expect(library.count, 0);
  });

  test('a playback lookup reports newly missing files to listeners', () async {
    final file = await writeFile('lookup-missing.mp3', <int>[1]);
    final library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('lookup', 'Missing'),
        path: file.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    await file.delete();
    var notifications = 0;
    library.addListener(() => notifications++);
    expect(await library.localFileFor(_track('lookup', 'Missing')), isNull);
    expect(library.tracks.single.missing, isTrue);
    expect(notifications, 1);
    await library.refreshMissing();
    expect(library.tracks.single.missing, isTrue);
  });

  test('prefers the requested quality and then the highest tier', () async {
    final File low = await writeFile('low.mp3', <int>[1]);
    final File high = await writeFile('high.flac', <int>[2]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('9', '音质'),
        path: low.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.exhigh,
        addedAt: DateTime.fromMillisecondsSinceEpoch(100),
        modifiedAt: DateTime.now(),
      ),
      LocalTrack(
        track: _track('9', '音质'),
        path: high.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.lossless,
        addedAt: DateTime.fromMillisecondsSinceEpoch(200),
        modifiedAt: DateTime.now(),
      ),
    ]);
    expect(
      (await library.localFileFor(_track('9', '音质')))?.path,
      native(high.path),
    );
    expect(
      (await library.localFileFor(
        _track('9', '音质'),
        quality: AudioQuality.exhigh,
      ))?.path,
      native(low.path),
    );
  });

  test(
    'deleting a download removes the file, a scan only the record',
    () async {
      final File downloaded = await writeFile('download.mp3', <int>[1]);
      final File scanned = await writeFile('scan.mp3', <int>[2]);
      final LocalLibrary library = create();
      await library.load();
      await library.addTracks(<LocalTrack>[
        LocalTrack(
          track: _track('1', '下载'),
          path: downloaded.path,
          source: LocalTrackSource.download,
          addedAt: DateTime.now(),
          modifiedAt: DateTime.now(),
        ),
        LocalTrack(
          track: _track('2', '扫描'),
          path: scanned.path,
          source: LocalTrackSource.scan,
          addedAt: DateTime.now(),
          modifiedAt: DateTime.now(),
        ),
      ]);
      await library.remove(
        library.entryForPath(downloaded.path)!,
        deleteFile: true,
      );
      await library.remove(
        library.entryForPath(scanned.path)!,
        deleteFile: true,
      );
      expect(await downloaded.exists(), isFalse);
      expect(await scanned.exists(), isTrue);
      expect(library.count, 0);
    },
  );

  test('the same path is indexed once and keeps the download source', () async {
    final File file = await writeFile('same.mp3', <int>[1]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('scan', '扫描'),
        path: file.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('download', '下载'),
        path: file.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.exhigh,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    expect(library.count, 1);
    expect(library.tracks.single.source, LocalTrackSource.download);
    expect(library.tracks.single.track.id, 'download');
  });

  test(
    'a single batch merges duplicate paths with download precedence',
    () async {
      final file = await writeFile('batch.mp3', <int>[1]);
      final library = create();
      final firstAdded = DateTime(2020);
      LocalTrack entry(String id, LocalTrackSource source, DateTime added) =>
          LocalTrack(
            track: _track(id, id),
            path: file.path,
            source: source,
            addedAt: added,
            modifiedAt: DateTime(2024),
          );
      await library.addTracks(<LocalTrack>[
        entry('scan', LocalTrackSource.scan, firstAdded),
        entry('download', LocalTrackSource.download, DateTime(2021)),
        entry('scan-again', LocalTrackSource.scan, DateTime(2022)),
      ]);
      expect(library.count, 1);
      expect(library.tracks.single.track.id, 'download');
      expect(library.tracks.single.source, LocalTrackSource.download);
      expect(library.tracks.single.addedAt, firstAdded);
    },
  );

  test('scan roots persist and can drop only their scanned entries', () async {
    final Directory music = Directory('${root.path}/Music');
    await music.create(recursive: true);
    final File inside = File('${music.path}/inside.mp3');
    await inside.writeAsBytes(<int>[1]);
    final LocalLibrary library = create();
    await library.load();
    await library.addScanRoot(music.path);
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('inside', '扫描'),
        path: inside.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    final LocalLibrary reopened = create();
    await reopened.load();
    expect(reopened.scanRoots, <String>[native(music.path)]);
    await reopened.removeScannedUnder(music.path);
    expect(reopened.count, 0);
    expect(await inside.exists(), isTrue);
  });

  test(
    'refresh ignores removed or replaced records while a file check is pending',
    () async {
      final File first = await writeFile('first.mp3', <int>[1]);
      final File second = await writeFile('second.mp3', <int>[2]);
      final Completer<bool> checked = Completer<bool>();
      final Completer<void> started = Completer<void>();
      final List<String> calls = <String>[];
      final library = LocalLibrary(
        supportDirectory: () async => support,
        documentsDirectory: () async => documents,
        fileExists: (String path) {
          calls.add(path);
          if (!started.isCompleted) started.complete();
          return checked.future;
        },
      );
      addTearDown(library.dispose);
      LocalTrack entry(File file, String id) => LocalTrack(
        track: _track(id, id),
        path: file.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime(2020),
        modifiedAt: DateTime(2020),
      );
      await library.addTracks([entry(first, 'old'), entry(second, 'removed')]);
      final old = library.tracks.first;
      final removed = library.tracks.last;
      final refresh = library.refreshMissing();
      await started.future;
      await library.addTracks([entry(first, 'new')]);
      await library.remove(removed);
      checked.complete(false);
      await refresh;
      expect(calls, hasLength(1));
      expect(library.tracks.single.id, 'new');
      expect(library.tracks.single.missing, isFalse);
      expect(old.missing, isFalse);
      expect(library.verifying, isFalse);
    },
  );

  test(
    'file lookup yields and ignores a candidate removed during another check',
    () async {
      final first = await writeFile('quality-first.mp3', [1]);
      final second = await writeFile('quality-second.mp3', [2]);
      final pending = Completer<bool>();
      final started = Completer<void>();
      final library = LocalLibrary(
        supportDirectory: () async => support,
        documentsDirectory: () async => documents,
        fileExists: (path) {
          if (path == native(first.path)) return Future<bool>.value(true);
          started.complete();
          return pending.future;
        },
      );
      addTearDown(library.dispose);
      LocalTrack entry(File file, AudioQuality quality) => LocalTrack(
        track: _track('same', 'Song'),
        path: file.path,
        source: LocalTrackSource.download,
        quality: quality,
        addedAt: DateTime(2020),
        modifiedAt: DateTime(2020),
      );
      await library.addTracks([
        entry(first, AudioQuality.lossless),
        entry(second, AudioQuality.exhigh),
      ]);
      final lookup = library.localFileFor(_track('same', 'Song'));
      await started.future;
      await library.remove(library.tracks.first);
      pending.complete(true);
      expect((await lookup)?.path, native(second.path));
    },
  );

  test('a refresh reports outside the caller, never inside it', () async {
    final File file = await writeFile('music/late.mp3', <int>[1, 2]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('late', 'Song'),
        path: file.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
    ]);
    int notifications = 0;
    library.addListener(() => notifications++);

    final Future<void> pending = library.refreshMissing();
    expect(
      notifications,
      0,
      reason:
          'callers include initState, so the first report must not run '
          'inside the call: marking widgets dirty there throws',
    );
    expect(library.verifying, isTrue);

    await pending;
    expect(notifications, greaterThan(0));
    expect(library.verifying, isFalse);
  });

  testWidgets('a scan started while a page mounts leaves its neighbours alone', (
    tester,
  ) async {
    late LocalLibrary library;
    await tester.runAsync(() async {
      final File file = await writeFile('music/mount.mp3', <int>[1]);
      library = create();
      await library.load();
      await library.addTracks(<LocalTrack>[
        LocalTrack(
          track: _track('mount', 'Song'),
          path: file.path,
          source: LocalTrackSource.scan,
          addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ]);
    });

    // The AnimatedBuilder stands in for the library card that is still mounted
    // in the page being swapped out; the scanner mounts beside it, like the
    // local music page replacing the library page.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              AnimatedBuilder(
                animation: library,
                builder: (BuildContext context, Widget? child) =>
                    const Text('card'),
              ),
              _ScanOnMount(library: library),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'a library report during build must not mark a sibling dirty',
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

/// Starts an index check from `initState`, the way the local music page does.
class _ScanOnMount extends StatefulWidget {
  const _ScanOnMount({required this.library});

  final LocalLibrary library;

  @override
  State<_ScanOnMount> createState() => _ScanOnMountState();
}

class _ScanOnMountState extends State<_ScanOnMount> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.library.refreshMissing());
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
