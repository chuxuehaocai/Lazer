import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';

void main() {
  late Directory directory;
  late DiskCache disk;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-cache-settle-');
    disk = DiskCache(directory: () async => directory);
  });
  tearDown(() async {
    await disk.settle();
    await directory.delete(recursive: true);
  });

  test(
    'settle joins an active stream write and maintenance it schedules later',
    () async {
      final body = StreamController<List<int>>();
      final opened = Completer<void>();
      final writing = disk.put(CacheBucket.audio, 'pending', () {
        opened.complete();
        return body.stream;
      });
      await opened.future;
      var finished = false;
      final settled = disk.settle().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      final early = finished;
      body.add([1, 2, 3]);
      await body.close();
      final file = await writing;
      await settled;
      expect(early, isFalse);
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), [1, 2, 3]);
      expect(
        await directory
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('.part'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'settle joins queued JSON replacement and invalidation before put starts',
    () async {
      final opening = Completer<Directory>();
      disk = DiskCache(directory: () => opening.future);
      final first = disk.writeJson('metadata', {'value': 'old'});
      final replacement = disk.writeJson('metadata', {'value': 'new'});
      final invalidation = disk.expireJson('metadata');
      var finished = false;
      final settled = disk.settle().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      final early = finished;
      opening.complete(directory);
      await Future.wait([first, replacement, invalidation]);
      await settled;
      expect(early, isFalse);
      final saved = await disk.readJson('metadata');
      expect(saved!.data['value'], 'new');
      expect(saved.invalidated, isTrue);
    },
  );

  test(
    'settle joins find and removal that can still create bucket directories',
    () async {
      final opening = Completer<Directory>();
      disk = DiskCache(directory: () => opening.future);
      final finding = disk.find(CacheBucket.audio, 'missing');
      final removing = disk.remove(CacheBucket.artwork, 'missing');
      var finished = false;
      final settled = disk.settle().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      final early = finished;
      opening.complete(directory);
      await finding;
      await removing;
      await settled;
      expect(early, isFalse);
    },
  );
}
