import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/storage/all_files_access.dart';
import 'package:lazer_nextgen/storage/app_storage.dart';
import 'package:lazer_nextgen/storage/storage_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory, support, cache, documents, destination;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('lazer-storage-');
    support = await Directory('${directory.path}/old-support').create();
    cache = await Directory('${directory.path}/old-cache').create();
    documents = await Directory('${directory.path}/old-documents').create();
    destination = Directory('${directory.path}/new-data');
  });
  tearDown(() => directory.delete(recursive: true));

  AppStorage storage() => AppStorage(
    supported: true,
    support: () async => support,
    cache: () async => cache,
    documents: () async => documents,
  );

  test(
    'directory changes migrate data and absolute references on next launch',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final oldSong = await File(
        '${cache.path}/song.mp3',
      ).writeAsBytes([1, 2, 3]);
      await File('${support.path}/local_library.json').writeAsString(
        jsonEncode({
          'tracks': [
            {'path': oldSong.path},
          ],
        }),
      );
      final font = await File(
        '${support.path}/custom.ttf',
      ).writeAsBytes([4, 5]);
      await prefs.setString(
        'lazer_font_preferences',
        jsonEncode({'path': font.path}),
      );
      await prefs.setString(
        'lazer_recent_tracks_v1',
        jsonEncode([
          {'localPath': oldSong.uri.toString()},
        ]),
      );
      final current = storage();
      await current.initialize(prefs);
      await current.schedule(destination.path);
      expect(current.requiresRestart, isTrue);
      expect((await current.supportDirectory()).path, support.path);
      final restarted = storage();
      await restarted.initialize(prefs);
      expect(restarted.error, isNull);
      expect(restarted.requiresRestart, isFalse);
      final manifest = jsonDecode(
        await File(
          '${destination.path}/support/local_library.json',
        ).readAsString(),
      );
      expect(
        File(manifest['tracks'][0]['path'] as String).uri.normalizePath(),
        File('${destination.path}/cache/song.mp3').uri.normalizePath(),
      );
      expect(await File('${destination.path}/cache/song.mp3').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(
        File(
          jsonDecode(prefs.getString('lazer_font_preferences')!)['path']
              as String,
        ).uri.normalizePath(),
        File('${destination.path}/support/custom.ttf').uri.normalizePath(),
      );
      expect(
        await oldSong.exists(),
        isTrue,
        reason: 'migration retains its original copy',
      );
      await restarted.schedule(null);
      final restored = storage();
      await restored.initialize(prefs);
      expect((await restored.supportDirectory()).path, support.path);
      expect(prefs.containsKey(AppStorage.rootKey), isFalse);
    },
  );

  test(
    'rejected and failed destinations preserve the active data directory',
    () async {
      final current = storage();
      final prefs = await SharedPreferences.getInstance();
      await current.initialize(prefs);
      await expectLater(
        current.schedule('relative/path'),
        throwsFormatException,
      );
      await expectLater(
        current.schedule('${support.path}/nested'),
        throwsFormatException,
      );
      final occupied = await Directory(
        '${destination.path}/support',
      ).create(recursive: true);
      await File('${occupied.path}/foreign.txt').writeAsString('untouched');
      await expectLater(
        current.schedule(destination.path),
        throwsFormatException,
      );
      expect(
        await File('${occupied.path}/foreign.txt').readAsString(),
        'untouched',
      );
      final blocker = await File(
        '${directory.path}/blocked',
      ).writeAsString('file');
      await prefs.setString(AppStorage.pendingKey, blocker.path);
      final restarted = storage();
      await restarted.initialize(prefs);
      expect(restarted.error, isNotNull);
      expect((await restarted.supportDirectory()).path, support.path);
      expect(prefs.containsKey(AppStorage.rootKey), isFalse);
    },
  );

  test(
    'an unavailable selected root falls back without erasing its preference',
    () async {
      final blocker = await File(
        '${directory.path}/unavailable',
      ).writeAsString('not a directory');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppStorage.rootKey, blocker.path);
      final current = storage();
      await current.initialize(prefs);
      expect(current.error, isNotNull);
      expect((await current.supportDirectory()).path, support.path);
      expect(prefs.getString(AppStorage.rootKey), blocker.path);
      expect(current.requestedRoot, blocker.absolute.uri.toFilePath());
    },
  );

  testWidgets('storage UI requests access before persisting a path', (
    tester,
  ) async {
    final current = storage();
    final methods = <String>[];
    var granted = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      AllFilesAccess.channel,
      (call) async {
        methods.add(call.method);
        if (call.method == 'requestAllFilesAccess') granted = true;
        return granted;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AllFilesAccess.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StorageSettings(
            storage: current,
            access: const AllFilesAccess(android: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('change-data-directory')));
    await tester.pumpAndSettle();
    expect(methods, contains('requestAllFilesAccess'));
    await tester.enterText(
      find.byKey(const ValueKey('data-directory-input')),
      destination.path,
    );
    await tester.tap(find.byKey(const ValueKey('save-data-directory')));
    await tester.pump();
    for (var turn = 0; turn < 100 && !current.requiresRestart; turn++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(current.requiresRestart, isTrue);
    expect(find.text('重启应用后生效，已有数据将迁移到新目录。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('denied all-files permission leaves the directory unchanged', (
    tester,
  ) async {
    final current = storage();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      AllFilesAccess.channel,
      (_) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AllFilesAccess.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StorageSettings(
            storage: current,
            access: const AllFilesAccess(android: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('change-data-directory')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('data-directory-input')), findsNothing);
    expect(current.requiresRestart, isFalse);
  });
}
