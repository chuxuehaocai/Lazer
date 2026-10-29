// End-to-end check of the growing-file reader bridge, without the engine.
//
// It drives the exported C callbacks exactly as the engine would, over a cache
// file that keeps growing while a read is blocked. This is the part of the port
// that cannot be covered by a pure-Dart test (the whole reason the bridge exists
// is that Dart cannot service a blocking native callback), so it runs as a plain
// script against a built bridge library:
//
//   cmake -S native -B build/native-audio -G "Ninja"   # or any generator
//   cmake --build build/native-audio
//   LAZER_AUDIO_BRIDGE_LIBRARY=build/native-audio/lazer-audio-bridge/lazer-audio-bridge.dll \
//     dart tool/native_bridge_check.dart
//
// Exits non-zero on the first failed expectation.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

const int _eof = -1;
const int _ioError = -2;

int _failures = 0;

void _expect(String what, Object? actual, Object? expected) {
  final bool ok = '$actual' == '$expected';
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $what: $actual'
      '${ok ? '' : ' (expected $expected)'}');
  if (!ok) _failures++;
}

typedef _ReadNative =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32);
typedef _ReadDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _SeekNative = Int64 Function(Pointer<Void>, Int64);
typedef _SeekDart = int Function(Pointer<Void>, int);
typedef _LengthNative = Int64 Function(Pointer<Void>);
typedef _LengthDart = int Function(Pointer<Void>);
typedef _VoidNative = Void Function(Pointer<Void>);
typedef _VoidDart = void Function(Pointer<Void>);

String _libraryPath() {
  final String? override =
      Platform.environment['LAZER_AUDIO_BRIDGE_LIBRARY'];
  if (override != null && override.isNotEmpty) return override;
  // Search the layouts both the CMake build and `tool/build_native_audio.dart`
  // produce, so this works without an environment variable.
  for (final Directory root in <Directory>[
    Directory('build/native-audio'),
    Directory('build/native-audio/cmake'),
  ]) {
    if (!root.existsSync()) continue;
    for (final FileSystemEntity entity in root.listSync(recursive: true)) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (name == 'lazer-audio-bridge.dll' ||
          name == 'liblazer-audio-bridge.so' ||
          name == 'liblazer-audio-bridge.dylib') {
        return entity.absolute.path;
      }
    }
  }
  stderr.writeln(
    'No bridge library found. Build it first:\n'
    '  cmake -S native -B build/native-audio && cmake --build build/native-audio\n'
    'or set LAZER_AUDIO_BRIDGE_LIBRARY to its path.',
  );
  exit(2);
}

/// Reads [length] bytes through the bridge in another isolate, so this isolate
/// stays free to append to the file and prove the read really blocked.
Future<int> _readInWorker(
  String libraryPath,
  int readerAddress,
  int length,
) async {
  final ReceivePort replies = ReceivePort();
  await Isolate.spawn<(String, int, int, SendPort)>((
    (String, int, int, SendPort) message,
  ) {
    final (String path, int address, int size, SendPort reply) = message;
    final DynamicLibrary library = DynamicLibrary.open(path);
    final _ReadDart read = library.lookupFunction<_ReadNative, _ReadDart>(
      'lazer_bridge_reader_read',
    );
    final Pointer<Uint8> buffer = calloc<Uint8>(size);
    final int count = read(Pointer<Void>.fromAddress(address), buffer, size);
    reply.send(count);
    calloc.free(buffer);
  }, (libraryPath, readerAddress, length, replies.sendPort));
  final Object? result = await replies.first;
  replies.close();
  return result! as int;
}

Future<void> main() async {
  final String libraryPath = _libraryPath();
  final DynamicLibrary library = DynamicLibrary.open(libraryPath);
  final LazerAudioBridgeApi api = LazerAudioBridgeApi(library);
  final _ReadDart read = library.lookupFunction<_ReadNative, _ReadDart>(
    'lazer_bridge_reader_read',
  );
  final _LengthDart length = library.lookupFunction<_LengthNative, _LengthDart>(
    'lazer_bridge_reader_length',
  );
  final _VoidDart cancel = library.lookupFunction<_VoidNative, _VoidDart>(
    'lazer_bridge_reader_cancel',
  );

  final Directory directory = await Directory.systemTemp.createTemp(
    'lazer-bridge-check',
  );
  final File file = File('${directory.path}/growing.audio');
  await file.writeAsBytes(<int>[]);
  final Pointer<Pointer<Void>> out = calloc<Pointer<Void>>();
  final int created = api.readerCreate(
    file.path.toNativeUtf8().cast<Uint8>(),
    16,
    out,
  );
  _expect('reader created', created, 0);
  final Pointer<Void> reader = out.value;
  calloc.free(out);
  final int address = reader.address;

  // 1. Nothing on disk yet: a read must block until bytes land, not report EOF.
  final Future<int> blocked = _readInWorker(libraryPath, address, 8);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final RandomAccessFile sink = await file.open(mode: FileMode.append);
  sink.writeFromSync(<int>[1, 2, 3, 4]);
  await sink.flush();
  api.readerNotify(reader);
  _expect('read waits for the first bytes', await blocked, 4);

  // 2. Sequential reads continue from where the last one stopped.
  sink.writeFromSync(<int>[5, 6, 7]);
  await sink.flush();
  api.readerNotify(reader);
  final Pointer<Uint8> buffer = calloc<Uint8>(16);
  _expect(
    'second read returns the appended bytes',
    read(reader, buffer, 8),
    3,
  );
  _expect('read is positioned after the payload', buffer[0], 5);

  // 3. A seek past the downloaded region waits for the download like a slow
  //    file, then lands on the requested offset.
  final Future<int> blockedSeek = Isolate.run<int>(() {
    final DynamicLibrary isolateLibrary = DynamicLibrary.open(libraryPath);
    final int Function(Pointer<Void>, int) isolateSeek = isolateLibrary
        .lookupFunction<_SeekNative, _SeekDart>('lazer_bridge_reader_seek');
    // Park the isolate while this isolate appends; the native call blocks natively.
    return isolateSeek(Pointer<Void>.fromAddress(address), 10);
  });
  await Future<void>.delayed(const Duration(milliseconds: 100));
  sink.writeFromSync(<int>[8, 9, 10, 11, 12, 13]);
  await sink.flush();
  api.readerNotify(reader);
  _expect('seek waits for bytes that have not landed', await blockedSeek, 10);

  // 4. The announced length is reported before the download finishes.
  _expect('length is the announced total', length(reader), 16);

  // 5. Finishing the download turns the exhausted stream into a clean EOF.
  sink.writeFromSync(<int>[14, 15, 16]);
  await sink.flush();
  await sink.close();
  api.readerNotify(reader);
  // seek(10) left six bytes (10..15) before the announced end of 16.
  _expect('read up to the announced end', read(reader, buffer, 8), 6);
  api.readerFinish(reader, 0);
  _expect('clean EOF after finish', read(reader, buffer, 8), _eof);

  // 6. A failed download reports a terminal error instead of a short file.
  final File failedFile = File('${directory.path}/failed.audio');
  await failedFile.writeAsBytes(<int>[1, 2]);
  final Pointer<Pointer<Void>> failedOut = calloc<Pointer<Void>>();
  api.readerCreate(
    failedFile.path.toNativeUtf8().cast<Uint8>(),
    -1,
    failedOut,
  );
  final Pointer<Void> failedReader = failedOut.value;
  calloc.free(failedOut);
  _expect('failed reader reads its bytes', read(failedReader, buffer, 8), 2);
  api.readerFinish(failedReader, 1);
  _expect(
    'failed download is a terminal error',
    read(failedReader, buffer, 8),
    _ioError,
  );

  // 7. Cancel wakes a read that is still waiting for bytes, which is what lets
  //    stop() interrupt a download that never delivers. The stream stays open
  //    (no `finish`) so only the cancel can unblock it.
  final File stalledFile = File('${directory.path}/stalled.audio');
  await stalledFile.writeAsBytes(<int>[]);
  final Pointer<Pointer<Void>> stalledOut = calloc<Pointer<Void>>();
  api.readerCreate(stalledFile.path.toNativeUtf8().cast<Uint8>(), -1, stalledOut);
  final Pointer<Void> stalledReader = stalledOut.value;
  calloc.free(stalledOut);
  final Future<int> cancelled = _readInWorker(
    libraryPath,
    stalledReader.address,
    4,
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));
  cancel(stalledReader);
  _expect('cancel interrupts a blocked read', await cancelled, _ioError);

  api.readerDestroy(reader);
  api.readerDestroy(failedReader);
  api.readerDestroy(stalledReader);
  calloc.free(buffer);
  await directory.delete(recursive: true);

  stdout.writeln(
    _failures == 0
        ? 'bridge check passed'
        : 'bridge check failed ($_failures expectations)',
  );
  exit(_failures == 0 ? 0 : 1);
}
