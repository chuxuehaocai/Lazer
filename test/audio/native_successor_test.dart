import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';

class _Api implements LazerAudioApi {
  @override
  int Function(Pointer<Void>, Pointer<LazerAudioStreamInfo>) get streamInfo =>
      (_, _) => lazerAudioErrorState;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter && invocation.memberName == #readLog) return null;
    return super.noSuchMethod(invocation);
  }
}

class _Bridge implements LazerAudioBridgeApi {
  int nextHandle = 10;
  @override
  int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>) get readerCreate =>
      (_, _, out) {
        out.value = Pointer<Void>.fromAddress(nextHandle++);
        return lazerAudioOk;
      };
  @override
  Pointer<NativeFunction<LazerAudioReadNative>> get readPointer => nullptr;
  @override
  Pointer<NativeFunction<LazerAudioSeekNative>> get seekPointer => nullptr;
  @override
  Pointer<NativeFunction<LazerAudioLengthNative>> get lengthPointer => nullptr;
  @override
  Pointer<NativeFunction<LazerAudioVoidNative>> get closePointer => nullptr;
  @override
  Pointer<NativeFunction<LazerAudioVoidNative>> get cancelPointer => nullptr;
  @override
  void Function(Pointer<Void>) get readerNotify => (_) {};
  @override
  void Function(Pointer<Void>, int) get readerFinish => (_, _) {};
  @override
  void Function(Pointer<Void>) get readerDestroy => (_) {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Worker implements LazerAudioWorker {
  int preparations = 0;
  int clears = 0;
  Completer<void>? delay;
  Completer<void>? openDelay, openStarted;
  @override
  Future<Object?> call(int op, List<Object?> params) async {
    if (op == LazerWorkerOp.clearQueuedReader) clears++;
    if (op == LazerWorkerOp.openReader && openDelay != null) {
      if (openStarted?.isCompleted == false) openStarted!.complete();
      await openDelay!.future;
    }
    if (op == LazerWorkerOp.queueReader) {
      preparations++;
      await delay?.future;
    }
    return lazerAudioOk;
  }

  @override
  Future<void> close() async {}
}

class _Cache extends AudioStreamCache {
  _Cache() : super(() async => Directory.systemTemp);
  final entries = <String, AudioStreamEntry>{};
  Completer<void>? delay, started;
  @override
  Future<AudioStreamEntry> open(
    String url, {
    int? expectedBytes,
    bool force = false,
  }) async {
    if (started?.isCompleted == false) started!.complete();
    await delay?.future;
    if (force) entries.remove(url);
    return entries.putIfAbsent(
      url,
      () => AudioStreamEntry(url: url, file: File(url), key: url.hashCode),
    );
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late NativeAudioEngine engine;
  late _Worker worker;
  late _Cache cache;
  setUp(() {
    worker = _Worker();
    cache = _Cache();
    engine = NativeAudioEngine.forTesting(
      api: _Api(),
      bridge: _Bridge(),
      worker: worker,
      cache: cache,
    );
  });
  tearDown(() async {
    await engine.stop();
    engine.dispose();
    await _settle();
  });

  test(
    'an appended successor does not prepare itself again at its boundary',
    () async {
      final queue = await engine.setQueue(['first.wav']);
      await engine.appendToQueue(queue, 'https://audio.test/second');
      await _settle();
      expect(worker.preparations, 1);
      engine.deliverEventForTesting(lazerAudioEventTrackChanged);
      await _settle();
      expect(worker.preparations, 1);
    },
  );

  test(
    'successive identical URLs each keep their own queue position',
    () async {
      await engine.setQueue([
        'first.wav',
        'https://audio.test/repeated',
        'https://audio.test/repeated',
        'https://audio.test/tail',
      ]);
      expect(await engine.playQueuedNext(), isTrue);
      // Manually opened repeated source consumes one pending position.
      expect(await engine.playQueuedNext(), isTrue);
      // The second repeat consumes exactly one more position.
      expect(await engine.playQueuedNext(), isTrue);
      expect(await engine.playQueuedNext(), isFalse);
    },
  );

  test(
    'a prepared repeat falls back without losing later queue positions',
    () async {
      const repeated = 'https://audio.test/repeated';
      await engine.setQueue([
        'first.wav',
        repeated,
        repeated,
        repeated,
        'https://audio.test/tail',
      ]);
      await engine.prepareSuccessorForTesting(repeated);
      expect(worker.preparations, 1);
      engine.deliverEventForTesting(lazerAudioEventTrackChanged);
      await _settle();
      expect(
        worker.preparations,
        1,
        reason: 'the active download keeps its reader',
      );
      expect(await engine.playQueuedNext(), isTrue);
      expect(await engine.playQueuedNext(), isTrue);
      expect(await engine.playQueuedNext(), isTrue);
      expect(await engine.playQueuedNext(), isFalse);
    },
  );

  test(
    'repeat completion keeps the shared download and its live callbacks',
    () async {
      const repeated = 'https://audio.test/repeated';
      final queue = await engine.setQueue([repeated]);
      final entry = cache.entries[repeated]!;
      final appended = entry.onAppended;
      final finished = entry.onFinished;
      var completions = 0;
      final subscription = engine.completed.listen((_) => completions++);
      await engine.appendToQueue(queue, repeated);
      await _settle();
      expect(worker.preparations, 0);
      expect(entry.onAppended, same(appended));
      expect(entry.onFinished, same(finished));
      engine.deliverEventForTesting(lazerAudioEventEnded);
      await _settle();
      expect(completions, 1);
      await engine.setQueue([repeated]);
      expect(
        entry.cancelled,
        isFalse,
        reason: 'the new active reader owns this download',
      );
      expect(engine.active, isTrue);
      await engine.stop();
      expect(
        entry.cancelled,
        isTrue,
        reason: 'explicit stop still releases the download',
      );
      await subscription.cancel();
    },
  );

  test(
    'manual skip into a prepared URL preserves its following duplicate',
    () async {
      const repeated = 'https://audio.test/repeated';
      await engine.setQueue([
        'first.wav',
        repeated,
        repeated,
        'https://audio.test/tail',
      ]);
      await engine.prepareSuccessorForTesting(repeated);
      expect(await engine.playQueuedNext(), isTrue);
      expect(await engine.playQueuedNext(), isTrue);
      expect(await engine.playQueuedNext(), isTrue);
      expect(await engine.playQueuedNext(), isFalse);
    },
  );

  test(
    'a delayed manual open does not consume a newly appended identical URL',
    () async {
      const repeated = 'https://audio.test/repeated';
      final queue = await engine.setQueue(['first.wav', repeated]);
      worker.openDelay = Completer<void>();
      worker.openStarted = Completer<void>();
      final crossing = engine.playQueuedNext();
      await worker.openStarted!.future;
      worker.delay = Completer<void>();
      await engine.appendToQueue(queue, repeated);
      await _settle();
      worker.openDelay!.complete();
      expect(await crossing, isTrue);
      // The original open consumed its own position; the later append is still
      // available to a second skip even while its preparation has not returned.
      expect(await engine.playQueuedNext(), isTrue);
      worker.delay!.complete();
      await _settle();
    },
  );

  test(
    'switching a prepared successor to repeat-current clears the old successor',
    () async {
      const repeated = 'https://audio.test/current';
      final queue = await engine.setQueue([repeated]);
      await engine.appendToQueue(queue, 'https://audio.test/old-next');
      await _settle();
      expect(worker.preparations, 1);
      await engine.appendToQueue(queue, repeated);
      await _settle();
      expect(worker.clears, 1);
      expect(cache.entries[repeated]!.cancelled, isFalse);
      final indexes = <int>[];
      final subscription = engine.indexStream.listen(indexes.add);
      engine.deliverEventForTesting(lazerAudioEventTrackChanged);
      await _settle();
      expect(indexes, isEmpty, reason: 'the old successor has been retired');
      expect(
        await engine.playQueuedNext(),
        isTrue,
        reason: 'the repeat is still pending',
      );
      await subscription.cancel();
    },
  );

  test('a late cache open cannot prepare into a replacement queue', () async {
    final queue = await engine.setQueue(['first.wav']);
    cache.delay = Completer<void>();
    cache.started = Completer<void>();
    await engine.appendToQueue(queue, 'https://audio.test/late');
    await cache.started!.future;
    await engine.setQueue(['replacement.wav']);
    cache.delay!.complete();
    await _settle();
    expect(worker.preparations, 0);
    expect(await engine.playQueuedNext(), isFalse);
  });

  test('a source replacement rejects a late successor preparation', () async {
    final queue = await engine.setQueue(['first.wav']);
    worker.delay = Completer<void>();
    await engine.appendToQueue(queue, 'https://audio.test/second');
    await _settle();
    await engine.setQueue(['replacement.wav']);
    worker.delay!.complete();
    await _settle();
    engine.deliverEventForTesting(lazerAudioEventTrackChanged);
    expect(await engine.playQueuedNext(), isFalse);
  });
}
