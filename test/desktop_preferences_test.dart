import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/storage/desktop_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late Directory directory;
  late File target;

  DesktopPreferencesStore open() =>
      DesktopPreferencesStore(file: () async => target);

  Future<Map<String, dynamic>> saved() async =>
      jsonDecode(await target.readAsString()) as Map<String, dynamic>;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-preferences-');
    target = File('${directory.path}/support/shared_preferences.json');
    SharedPreferences.resetStatic();
  });

  tearDown(() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await directory.delete(recursive: true);
  });

  test('keeps the stock file format and value types across launches', () async {
    final DesktopPreferencesStore store = open();
    SharedPreferencesStorePlatform.instance = store;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(await prefs.setBool('flag', true), isTrue);
    await prefs.setInt('count', 3);
    await prefs.setDouble('ratio', 1);
    await prefs.setString('name', 'Lazer "next"');
    await prefs.setStringList('items', <String>['a', 'b']);

    expect(await saved(), <String, Object?>{
      'flutter.flag': true,
      'flutter.count': 3,
      'flutter.ratio': 1.0,
      'flutter.name': 'Lazer "next"',
      'flutter.items': <String>['a', 'b'],
    });
    expect(await target.readAsString(), contains('"flutter.ratio":1.0'));
    expect(await File('${target.path}.tmp').exists(), isFalse);

    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = open();
    final SharedPreferences reopened = await SharedPreferences.getInstance();
    expect(reopened.getBool('flag'), isTrue);
    expect(reopened.getInt('count'), 3);
    expect(reopened.getDouble('ratio'), 1.0);
    expect(reopened.getString('name'), 'Lazer "next"');
    expect(reopened.getStringList('items'), <String>['a', 'b']);

    await reopened.remove('count');
    expect((await saved()).containsKey('flutter.count'), isFalse);
  });

  test('reads a file the stock store wrote and honours prefixes', () async {
    await target.parent.create(recursive: true);
    await target.writeAsString(
      '{"flutter.volume":0.5,"flutter.mode":"all","native.token":"keep"}',
    );
    final DesktopPreferencesStore store = open();
    expect(await store.getAll(), <String, Object>{
      'flutter.volume': 0.5,
      'flutter.mode': 'all',
    });
    expect(await store.clear(), isTrue);
    expect(await saved(), <String, Object?>{'native.token': 'keep'});
  });

  test('changes made together share one write', () async {
    final DesktopPreferencesStore store = open();
    final List<bool> results = await Future.wait(<Future<bool>>[
      for (var index = 0; index < 40; index++)
        store.setValue('Int', 'flutter.key$index', index),
    ]);
    expect(results, everyElement(isTrue));
    expect(store.debugWrites, 1);
    expect((await saved()).length, 40);

    await Future.wait(<Future<bool>>[
      for (var index = 0; index < 40; index++)
        store.setValue('Int', 'flutter.key$index', index + 100),
    ]);
    expect(store.debugWrites, 2);
    expect((await saved())['flutter.key39'], 139);
  });

  test('changes during a write are folded into a single follow-up', () async {
    Completer<void> gate = Completer<void>()..complete();
    final DesktopPreferencesStore store = DesktopPreferencesStore(
      file: () async {
        await gate.future;
        return target;
      },
    );
    await store.getAll();
    gate = Completer<void>();
    final Future<bool> first = store.setValue('Int', 'flutter.first', 1);
    await Future<void>.delayed(Duration.zero);
    final List<Future<bool>> later = <Future<bool>>[
      for (var index = 0; index < 20; index++)
        store.setValue('Int', 'flutter.later$index', index),
    ];
    var flushed = false;
    final Future<void> flushing = store.flush().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    gate.complete();
    expect(
      await Future.wait(<Future<bool>>[first, ...later]),
      everyElement(isTrue),
    );
    await flushing;
    expect(store.debugWrites, 2);
    expect((await saved()).length, 21);
  });

  test('a value that is already stored is not written again', () async {
    final DesktopPreferencesStore store = open();
    await store.setValue('String', 'flutter.name', 'x');
    await store.setValue('StringList', 'flutter.items', <String>['a']);
    expect(store.debugWrites, 2);

    expect(await store.setValue('String', 'flutter.name', 'x'), isTrue);
    expect(
      await store.setValue('StringList', 'flutter.items', <String>['a']),
      isTrue,
    );
    expect(await store.remove('flutter.missing'), isTrue);
    expect(store.debugWrites, 2);

    await store.setValue('Double', 'flutter.level', 1.0);
    expect(store.debugWrites, 3);
    await store.setValue('Int', 'flutter.level', 1);
    expect(store.debugWrites, 4);
    expect(await target.readAsString(), contains('"flutter.level":1}'));
  });

  test('a large snapshot is encoded off the calling isolate intact', () async {
    final DesktopPreferencesStore store = open();
    final String queue = jsonEncode(<String, Object>{
      'index': 3,
      'tracks': <Map<String, String>>[
        for (var index = 0; index < 4000; index++)
          <String, String>{'id': '$index', 'title': '歌曲 "$index"'},
      ],
    });
    expect(queue.length, greaterThan(65536));
    await store.setValue('String', 'flutter.queue', queue);
    await store.setValue('Bool', 'flutter.flag', true);

    final Map<String, Object> reopened = await open().getAll();
    expect(reopened['flutter.queue'], queue);
    expect(reopened['flutter.flag'], isTrue);
  });

  test(
    'an unreadable snapshot is kept aside instead of blocking startup',
    () async {
      await target.parent.create(recursive: true);
      await target.writeAsString('{"flutter.volume":0.5,"flutter.que');
      final DesktopPreferencesStore store = open();
      expect(await store.getAll(), isEmpty);
      expect(
        await File('${target.path}.corrupt').readAsString(),
        '{"flutter.volume":0.5,"flutter.que',
      );
      expect(await store.setValue('Bool', 'flutter.flag', true), isTrue);
      expect(await saved(), <String, Object?>{'flutter.flag': true});
    },
  );

  test('a failed write is reported and retried by the next change', () async {
    var available = true;
    final DesktopPreferencesStore store = DesktopPreferencesStore(
      file: () async => available
          ? target
          : throw const FileSystemException('profile is not mounted'),
    );
    expect(await store.getAll(), isEmpty);

    available = false;
    expect(await store.setValue('Bool', 'flutter.flag', true), isFalse);
    expect(await store.getAll(), <String, Object>{'flutter.flag': true});
    expect(await target.exists(), isFalse);

    available = true;
    expect(await store.setValue('Bool', 'flutter.flag', true), isTrue);
    expect(await saved(), <String, Object?>{'flutter.flag': true});
  });

  test('settings that could not be read are never overwritten', () async {
    await target.parent.create(recursive: true);
    await target.writeAsString('{"flutter.volume":0.5}');
    var available = false;
    final DesktopPreferencesStore store = DesktopPreferencesStore(
      file: () async => available
          ? target
          : throw const FileSystemException('profile is not mounted'),
    );
    SharedPreferencesStorePlatform.instance = store;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);

    available = true;
    expect(await prefs.setBool('flag', true), isFalse);
    expect(prefs.getBool('flag'), isTrue);
    await store.flush();
    expect(store.debugWrites, 0);
    expect(await target.readAsString(), '{"flutter.volume":0.5}');

    expect(await open().getAll(), <String, Object>{'flutter.volume': 0.5});
  });
}
