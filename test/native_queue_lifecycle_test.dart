import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/native_engine_ownership.dart';

class _Api implements LazerAudioApi {
  bool guardedClear = true;
  int fallbackStops = 0, destroys = 0;
  void Function()? releaseNative;
  @override
  int Function(Pointer<Void>) get stop => (_) {
    fallbackStops++;
    releaseNative?.call();
    return lazerAudioOk;
  };
  @override
  void Function(Pointer<Void>) get destroy => (_) {
    destroys++;
    releaseNative?.call();
  };
  @override
  int Function(Pointer<Void>, int)? get setAutoMix =>
      (_, _) => lazerAudioOk;
  @override
  int Function(Pointer<Void>, int)? get clearUnheardQueuedReader =>
      guardedClear ? (_, _) => lazerAudioOk : null;
  @override
  int Function(Pointer<Void>, Pointer<LazerAudioStreamInfo>) get streamInfo =>
      (_, _) => lazerAudioErrorState;
  @override
  String Function(Pointer<Void>) get lastError =>
      (_) => 'fixture rejected';
  @override
  int Function(Pointer<Void>, Pointer<Int32>, Pointer<Uint8>, int)?
  get readLog => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bridge implements LazerAudioBridgeApi {
  int handles = 0;
  final heldByNative = <int>{};
  final destroyed = <int>[];
  bool freedWhileHeld = false;
  @override
  int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>) get readerCreate =>
      (_, _, out) {
        out.value = Pointer<Void>.fromAddress(++handles);
        return lazerAudioOk;
      };
  @override
  void Function(Pointer<Void>) get readerDestroy => (handle) {
    freedWhileHeld |= heldByNative.contains(handle.address);
    destroyed.add(handle.address);
  };
  @override
  void Function(Pointer<Void>) get readerCancel => (_) {};
  @override
  void Function(Pointer<Void>, int) get readerFinish => (_, _) {};
  @override
  void Function(Pointer<Void>) get readerNotify => (_) {};
  @override
  void Function(Pointer<Void>, int)? get readerSetLength => null;
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Worker implements LazerAudioWorker {
  late _Bridge bridge;
  late _Api api;
  bool failClear = false,
      failStop = false,
      loseDestroyReply = false,
      cannotConfirmExit = false;
  int? queuedContext;
  Completer<void>? deviceGate;
  final deviceStarted = Completer<void>();
  int deviceCalls = 0, volumeCalls = 0;
  final firstQueue = Completer<void>();
  final gate = Completer<void>();
  final closed = Completer<void>();
  final order = <String>[];
  int queued = 0;
  int clearResult = lazerAudioOk;
  int openResult = lazerAudioOk;
  final overlaps = <int>[];
  @override
  Future<Object?> call(int op, List<Object?> params) async {
    if (op == LazerWorkerOp.setDevice) {
      deviceCalls++;
      final waiting = deviceGate;
      if (waiting != null) {
        if (!deviceStarted.isCompleted) deviceStarted.complete();
        await waiting.future;
        return lazerAudioErrorState;
      }
    }
    if (op == LazerWorkerOp.setVolume) volumeCalls++;
    if (op == LazerWorkerOp.openReader) return openResult;
    if (op == LazerWorkerOp.queueReader) {
      queuedContext = Pointer<LazerAudioReader>.fromAddress(
        params[2] as int,
      ).ref.context.address;
      bridge.heldByNative.add(queuedContext!);
      order.add('queue-${++queued}');
      if (queued == 1) {
        firstQueue.complete();
        await gate.future;
      }
    } else if (op == LazerWorkerOp.clearQueuedReader) {
      if (failClear) throw StateError('clear reply lost');
      if (clearResult == lazerAudioOk) {
        bridge.heldByNative.remove(queuedContext);
      }
      order.add('clear');
      return clearResult;
    } else if (op == LazerWorkerOp.setAutoMix) {
      overlaps.add(params[1] as int);
    } else if (op == LazerWorkerOp.stop) {
      if (failStop) throw StateError('stop reply lost');
      bridge.heldByNative.clear();
    } else if (op == LazerWorkerOp.destroy) {
      api.destroy(Pointer<Void>.fromAddress(params[0] as int));
      if (loseDestroyReply) throw StateError('destroy executed, reply lost');
    }
    return lazerAudioOk;
  }

  @override
  Future<void> close() async {
    if (!closed.isCompleted) closed.complete();
    if (cannotConfirmExit) throw StateError('worker exit unconfirmed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late _Worker worker;
  late _Api api;
  late NativeAudioEngine engine;
  late AudioStreamCache cache;
  late _Bridge bridge;
  late NativeEngineOwnershipBudget budget;
  late List<String> urls;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-native-queue-order-');
    urls = [];
    for (var index = 0; index < 4; index++) {
      final file = File('${root.path}/$index.flac');
      await file.writeAsBytes([index]);
      urls.add(file.uri.toString());
    }
    worker = _Worker();
    engine = NativeAudioEngine.forTesting(
      api: api = _Api(),
      bridge: bridge = _Bridge(),
      worker: worker,
      cache: cache = AudioStreamCache(() async => root, maximumEntries: 2),
      ownershipBudget: budget = NativeEngineOwnershipBudget(),
    );
    worker.bridge = bridge;
    worker.api = api;
    api.releaseNative = bridge.heldByNative.clear;
  });
  tearDown(() async {
    if (!worker.gate.isCompleted) worker.gate.complete();
    engine.dispose();
    await worker.closed.future;
    await engine.shutdownSettled;
    await root.delete(recursive: true);
  });

  test(
    'lost clear reply stops and destroys before freeing its native reader',
    () async {
      final id = await engine.setQueue([urls[0]]);
      worker.gate.complete();
      await engine.appendToQueue(id, urls[1]);
      worker.failClear = true;
      await expectLater(engine.clearQueued(id), throwsStateError);
      await engine.shutdownSettled;
      expect(bridge.freedWhileHeld, isFalse);
      expect(bridge.destroyed, hasLength(1));
      expect(api.fallbackStops, 1);
      expect(api.destroys, 1);
      expect(budget.blocked, isFalse);
      expect(budget.busy, isFalse);
      expect(engine.workerFailure, isNotNull);
      expect(await engine.appendToQueue(id, urls[2]), isFalse);
    },
  );

  test(
    'destroy executed without a reply is never repeated and retains one owner',
    () async {
      final id = await engine.setQueue([urls[0]]);
      worker.gate.complete();
      await engine.appendToQueue(id, urls[1]);
      worker.loseDestroyReply = true;
      engine.dispose();
      await engine.shutdownSettled;
      expect(api.destroys, 1);
      expect(api.fallbackStops, 0);
      expect(bridge.destroyed, isEmpty);
      expect(budget.blocked, isTrue);
      expect(engine.workerFailure, contains('restart'));
      expect(
        () => NativeAudioEngine.forTesting(
          api: api,
          bridge: bridge,
          worker: worker,
          cache: cache,
          ownershipBudget: budget,
        ),
        throwsStateError,
      );
      expect(() => budget.retain(Object()), throwsStateError);
    },
  );

  test(
    'unconfirmed worker exit cannot authorize fallback or free a held reader',
    () async {
      final id = await engine.setQueue([urls[0]]);
      worker.gate.complete();
      await engine.appendToQueue(id, urls[1]);
      worker.failStop = true;
      worker.cannotConfirmExit = true;
      engine.dispose();
      await engine.shutdownSettled;
      expect(api.destroys, 0);
      expect(api.fallbackStops, 0);
      expect(bridge.heldByNative, hasLength(1));
      expect(bridge.destroyed, isEmpty);
      expect(bridge.freedWhileHeld, isFalse);
      expect(budget.blocked, isTrue);
    },
  );

  test(
    'normal disposal retains a just-accepted successor until native destroy',
    () async {
      final id = await engine.setQueue([urls[0]]);
      final preparing = engine.appendToQueue(id, urls[1]);
      await worker.firstQueue.future;
      worker.clearResult = lazerAudioQueueAlreadyActive;
      engine.dispose();
      worker.gate.complete();
      expect(await preparing, isFalse);
      await engine.shutdownSettled;
      expect(bridge.freedWhileHeld, isFalse);
      expect(bridge.destroyed, hasLength(1));
      expect(api.destroys, 1);
      expect(budget.busy, isFalse);
    },
  );

  test(
    'a delayed settings result cannot submit more RPCs after disposal starts',
    () async {
      final gate = worker.deviceGate = Completer<void>();
      final loading = engine.setQueue([urls[0]]);
      final rejected = expectLater(
        loading,
        throwsA(isA<LazerWorkerNotSubmitted>()),
      );
      await worker.deviceStarted.future;
      engine.dispose();
      gate.complete();
      await rejected;
      await engine.shutdownSettled;
      expect(worker.deviceCalls, 1);
      expect(worker.volumeCalls, 0);
      expect(api.destroys, 1);
    },
  );

  test('native clear is ordered before an append invoked after it', () async {
    final id = await engine.setQueue([urls[0]]);
    final first = engine.appendToQueue(id, urls[1]);
    await worker.firstQueue.future;
    final clear = engine.clearQueued(id);
    final following = engine.appendToQueue(id, urls[2]);
    worker.gate.complete();
    expect(await first, isTrue);
    expect(await clear, isTrue);
    expect(await following, isTrue);
    expect(worker.order, ['queue-1', 'clear', 'queue-2']);
    expect(engine.queuedSourceUrl, urls[2]);
  });

  test(
    'native active and queued readers pin their cache files until release',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = 1024;
        request.response.add([1, 2, 3, 4]);
        try {
          await request.response.flush();
        } catch (_) {}
      });
      try {
        final base = 'http://${server.address.host}:${server.port}';
        final id = await engine.setQueue(['$base/active']);
        final audible = await cache.open('$base/active');
        expect(audible.leased, isTrue);
        worker.gate.complete();
        expect(await engine.appendToQueue(id, '$base/queued'), isTrue);
        final queued = await cache.open('$base/queued');
        expect(queued.leased, isTrue);
        await expectLater(cache.open('$base/newest'), throwsStateError);
        expect(await engine.clearQueued(id), isTrue);
        expect(queued.leased, isFalse);
        expect(queued.cancelled, isTrue);
        await cache.open('$base/newest');
        expect(audible.cancelled, isFalse);
        expect(await audible.file.exists(), isTrue);
        await engine.stop();
        expect(audible.leased, isFalse);
        expect(audible.cancelled, isTrue);
        await audible.done;
        await engine.clearCache();
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'native source rejection releases its lease before discarding bytes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      try {
        final url = 'http://${server.address.host}:${server.port}/rejected';
        final rejected = await cache.open(url);
        await rejected.done;
        worker.openResult = lazerAudioErrorSource;
        await expectLater(engine.setQueue([url]), throwsStateError);
        expect(rejected.leased, isFalse);
        expect(await rejected.file.exists(), isFalse);
        final retried = await cache.open(url);
        expect(identical(retried, rejected), isFalse);
        await retried.done;
        await engine.clearCache();
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'native superseded preparation returns false to its own append',
    () async {
      final id = await engine.setQueue([urls[0]]);
      final first = engine.appendToQueue(id, urls[1]);
      await worker.firstQueue.future;
      final superseded = engine.appendToQueue(id, urls[2]);
      final latest = engine.appendToQueue(id, urls[3]);
      expect(await superseded, isFalse);
      worker.gate.complete();
      expect(await first, isTrue);
      expect(await latest, isTrue);
      expect(worker.order, ['queue-1', 'queue-2']);
      expect(engine.queuedSourceUrl, urls[3]);
    },
  );
  test(
    'native guarded clear preserves a successor already audible before its Dart event',
    () async {
      final id = await engine.setQueue([urls[0]]);
      worker.gate.complete();
      expect(await engine.appendToQueue(id, urls[1]), isTrue);
      worker.clearResult = lazerAudioQueueAlreadyAudible;
      expect(await engine.clearQueued(id), isFalse);
      expect(engine.queuedSourceUrl, urls[1]);
    },
  );
  test(
    'older engines without guarded clear retain their accepted successor',
    () async {
      final id = await engine.setQueue([urls[0]]);
      worker.gate.complete();
      await engine.appendToQueue(id, urls[1]);
      api.guardedClear = false;
      expect(await engine.clearQueued(id), isFalse);
      expect(engine.queuedSourceUrl, urls[1]);
      expect(worker.order, ['queue-1']);
    },
  );
  test(
    'native mix duration defaults to 5 seconds and clamps to 1 through 13',
    () async {
      await engine.setAutoMixEnabled(true);
      await engine.setAutoMixEnabled(
        true,
        duration: const Duration(seconds: 30),
      );
      await engine.setAutoMixEnabled(true, duration: Duration.zero);
      await engine.setAutoMixEnabled(
        false,
        duration: const Duration(seconds: 9),
      );
      expect(worker.overlaps, [5000, 13000, 1000, 0]);
    },
  );
}
