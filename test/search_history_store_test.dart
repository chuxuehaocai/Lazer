import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/search_history_store.dart';

/// In-memory stand-in for the preferences slot the store persists into.
class _Slot {
  String? value;
  int writes = 0;

  Future<String?> read() async => value;

  Future<void> write(String next) async {
    writes++;
    value = next;
  }
}

SearchHistoryStore _storeFor(_Slot slot) {
  return SearchHistoryStore(read: slot.read, write: slot.write);
}

void main() {
  test('keeps the newest queries first', () async {
    final _Slot slot = _Slot();
    final SearchHistoryStore store = _storeFor(slot);
    await store.record('alpha');
    await store.record('beta');
    expect(await store.load(), <String>['beta', 'alpha']);
  });

  test('repeating a query moves it up instead of saving it twice', () async {
    final _Slot slot = _Slot();
    final SearchHistoryStore store = _storeFor(slot);
    await store.record('alpha');
    await store.record('beta');
    // Case and surrounding space do not make a second entry.
    await store.record('  ALPHA ');
    expect(await store.load(), <String>['ALPHA', 'beta']);
  });

  test('caps the history at the documented limit', () async {
    final _Slot slot = _Slot();
    final SearchHistoryStore store = _storeFor(slot);
    for (int i = 0; i < searchHistoryLimit + 4; i++) {
      await store.record('query $i');
    }
    final List<String> saved = await store.load();
    expect(saved, hasLength(searchHistoryLimit));
    expect(saved.first, 'query ${searchHistoryLimit + 3}');
    expect(saved.contains('query 0'), isFalse);
  });

  test('ignores empty queries', () async {
    final _Slot slot = _Slot();
    final SearchHistoryStore store = _storeFor(slot);
    await store.record('   ');
    await store.record('');
    expect(await store.load(), isEmpty);
    expect(slot.writes, 0);
    expect(slot.value, isNull);
  });

  test('reads a missing or malformed value as an empty history', () async {
    final _Slot slot = _Slot();
    final SearchHistoryStore store = _storeFor(slot);
    expect(await store.load(), isEmpty);
    slot.value = '{not json';
    expect(await store.load(), isEmpty);
    slot.value = '{"query":"alpha"}';
    expect(await store.load(), isEmpty);
    slot.value = '["alpha", 7, " beta ", "alpha"]';
    expect(await store.load(), <String>['alpha', 'beta']);
  });

  test('forgets one query and clears the rest', () async {
    final _Slot slot = _Slot();
    final SearchHistoryStore store = _storeFor(slot);
    await store.record('alpha');
    await store.record('beta');
    await store.remove('ALPHA');
    expect(await store.load(), <String>['beta']);
    await store.record('gamma');
    await store.clear();
    expect(await store.load(), isEmpty);
  });

  test('overlapping records keep every entry', () async {
    final _Slot slot = _Slot();
    final Completer<void> gate = Completer<void>();
    final SearchHistoryStore store = SearchHistoryStore(
      read: slot.read,
      write: (String value) async {
        // Hold the first write open so the second record has to queue up.
        if (slot.writes == 0) await gate.future;
        await slot.write(value);
      },
    );
    final Future<void> first = store.record('alpha');
    final Future<void> second = store.record('beta');
    gate.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(await store.load(), <String>['beta', 'alpha']);
  });
}
