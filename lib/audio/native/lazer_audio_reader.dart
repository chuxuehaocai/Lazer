// The Dart handle for one growing cache file that the engine reads through.
//
// The byte source itself lives in `native/lazer-audio-bridge` because the
// engine's reader callbacks run on its decode thread and must return
// synchronously — Dart callbacks cannot do that. What Dart owns here is the
// lifecycle: create the reader for a cache file, wake it when the downloader
// appends bytes, tell it when the download finished or failed, and free it once
// the engine no longer references it.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'lazer_audio_abi.dart';
import 'lazer_audio_library.dart';

/// A reader the engine can open, kept alive until the stream is stopped.
class NativeStreamReader {
  NativeStreamReader._(this._bridge, this._handle, this._reader)
    : _readerAddress = _reader.address;

  /// Creates a reader over [path]. The file must exist; the engine blocks on
  /// reads until [notifyAppended] or [finish] is called.
  ///
  /// Returns null when the bridge rejected the path (for example a path it
  /// cannot open), so the caller can fall back instead of failing playback.
  static NativeStreamReader? create(
    LazerAudioBridgeApi bridge, {
    required String path,
    int? expectedBytes,
  }) {
    final Pointer<Utf8> pathPointer = path.toNativeUtf8();
    final Pointer<Pointer<Void>> out = calloc<Pointer<Void>>();
    try {
      final int status = bridge.readerCreate(
        pathPointer.cast<Uint8>(),
        expectedBytes ?? -1,
        out,
      );
      if (status != lazerAudioOk || out.value == nullptr) return null;
      final Pointer<LazerAudioReader> reader = calloc<LazerAudioReader>();
      reader.ref
        ..read = bridge.readPointer
        ..seek = bridge.seekPointer
        ..length = bridge.lengthPointer
        ..close = bridge.closePointer
        ..context = out.value
        ..cancel = bridge.cancelPointer;
      return NativeStreamReader._(bridge, out.value, reader);
    } finally {
      calloc.free(out);
      calloc.free(pathPointer);
    }
  }

  final LazerAudioBridgeApi _bridge;
  final Pointer<Void> _handle;
  final Pointer<LazerAudioReader> _reader;
  final int _readerAddress;
  bool _released = false;
  bool _finished = false;
  NativeCallable<LazerBridgeDemandNative>? _demandCallable;
  void Function(int offset, int kind)? _onDemand;

  /// The `LazerAudioReader` the engine's open/queue call takes. Valid until
  /// [release] runs; the address stays unique after release so a stale handle
  /// can be told apart from a live one.
  Pointer<LazerAudioReader> get pointer => _reader;

  /// Identity for diagnostics and for detecting a reader that a queued source
  /// still references after the applet moved on.
  int get address => _readerAddress;

  /// Bytes the cache file holds right now, or -1 before it exists.
  int get bytesAvailable => _bridge.readerBytesAvailable(_handle);

  /// Tells the reader which byte ranges of the track the cache file holds.
  ///
  /// A redirected download appends its body after the prefix, so the range
  /// `[windowStart, windowEnd)` of the track lives at file offset
  /// [windowFileStart]; the reader must map through that and never serve the gap
  /// between the two ranges as if it were audio. [rangeSupported] is false once
  /// the server has been seen ignoring `Range`.
  void setWindow({
    required int prefixEnd,
    required int windowStart,
    required int windowEnd,
    required int windowFileStart,
    required bool rangeSupported,
  }) {
    if (_released) return;
    _bridge.readerSetWindow?.call(
      _handle,
      prefixEnd,
      windowStart,
      windowEnd,
      windowFileStart,
      rangeSupported ? 1 : 0,
    );
  }

  /// Announces the track's total size once the download learns it.
  ///
  /// The engine passes it to the demuxer as the source length, which is how a
  /// demuxer turns a seek's timestamp into a byte offset.
  void setLength(int expectedBytes) {
    if (_released || expectedBytes <= 0) return;
    _bridge.readerSetLength?.call(_handle, expectedBytes);
  }

  /// Installs the callback that fetches a byte the reader is waiting for.
  ///
  /// [onDemand] runs on this isolate (never on the engine's thread), so it may
  /// await a download before the reader is woken by [notifyAppended]. Returns
  /// false when this bridge predates the demand protocol.
  bool setDemandListener(void Function(int offset, int kind) onDemand) {
    final setter = _bridge.readerSetDemandListener;
    if (_released || setter == null) return false;
    _onDemand = onDemand;
    final NativeCallable<LazerBridgeDemandNative> callable =
        _demandCallable ??= NativeCallable<LazerBridgeDemandNative>.listener(
          _handleDemand,
        );
    setter(_handle, callable.nativeFunction, nullptr);
    return true;
  }

  void _handleDemand(Pointer<Void> context, int offset, int kind) {
    _onDemand?.call(offset, kind);
  }

  /// The downloader appended bytes: wake a blocked read.
  void notifyAppended() {
    if (_released) return;
    _bridge.readerNotify(_handle);
  }

  /// No more bytes will arrive. [failed] makes the engine treat the source as
  /// broken once the buffered bytes are consumed, instead of a clean EOF.
  void finish({bool failed = false}) {
    if (_released || _finished) return;
    _finished = true;
    _bridge.readerFinish(_handle, failed ? 1 : 0);
  }

  /// Frees the native reader and its `LazerAudioReader` struct.
  ///
  /// Only call this after the engine stopped or replaced the source: the engine
  /// keeps the function pointers and context until then.
  void release() {
    if (_released) return;
    _released = true;
    // Destroying the reader is what stops the engine from calling the demand
    // listener, so the callable can only be closed afterwards.
    _bridge.readerDestroy(_handle);
    calloc.free(_reader);
    _onDemand = null;
    _demandCallable?.close();
    _demandCallable = null;
  }
}
