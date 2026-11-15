import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Compressed bytes only: never load the audio payload or decode full-size art
/// while scanning. The shared image provider handles bounded display decoding.
class EmbeddedArtwork {
  static const maxImageBytes = 4 * 1024 * 1024;

  /// Unsynchronisation can nearly double a JPEG before the image itself is capped.
  static const _maxFrameBytes = maxImageBytes + 1024 * 1024;
  static const _maxTagBytes = maxImageBytes * 2 + 1024 * 1024;
  static final _pending = <String, Future<String?>>{};

  static Future<String?> cacheUri(File audio, Directory cache) async {
    final stat = await audio.stat();
    if (stat.type != FileSystemEntityType.file) return null;
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              audio.absolute.path,
              stat.size,
              stat.modified.microsecondsSinceEpoch,
            ]),
          ),
        )
        .toString();
    final pendingKey = '${cache.path}/$key';
    final existing = _pending[pendingKey];
    if (existing != null) return existing;
    final task = _cache(audio, cache, key);
    _pending[pendingKey] = task;
    try {
      return await task;
    } finally {
      _pending.remove(pendingKey);
    }
  }

  static Future<String?> _cache(File audio, Directory cache, String key) async {
    final image = File('${cache.path}/$key.art');
    final absent = File('${cache.path}/$key.none');
    if (await image.exists()) {
      if (await image.length() > 0) return image.uri.toString();
      await image.delete();
    }
    if (await absent.exists()) return null;
    final bytes = await read(audio);
    await cache.create(recursive: true);
    if (bytes == null) {
      await absent.writeAsBytes(const []);
      return null;
    }
    final staging = File('${image.path}.$pid.tmp');
    try {
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(image.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
    return image.uri.toString();
  }

  static Future<Uint8List?> read(File audio) async {
    final file = await audio.open();
    try {
      final reader = _ArtworkReader(file, await file.length());
      final head = await reader.read(
        0,
        reader.length < 12 ? reader.length : 12,
      );
      _Picture? picture;
      if (_text(head, 0, 3) == 'ID3') {
        picture = await reader.id3(0, reader.length);
      } else if (_text(head, 0, 4) == 'fLaC') {
        picture = await reader.flac();
      } else if (_text(head, 4, 4) == 'ftyp') {
        picture = await reader.mp4(0, reader.length, 0);
      } else if (_text(head, 0, 4) == 'OggS') {
        picture = await reader.ogg();
      } else if (_text(head, 0, 4) == 'RIFF' || _text(head, 0, 4) == 'FORM') {
        picture = await reader.chunked(_text(head, 0, 4) == 'RIFF');
      }
      return picture?.bytes;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    } finally {
      await file.close();
    }
  }
}

typedef _Read = Future<Uint8List> Function(int offset, int count);

class _Picture {
  const _Picture(this.bytes, this.type);
  final Uint8List bytes;
  final int type;
}

class _ArtworkReader {
  _ArtworkReader(this.file, this.length);
  final RandomAccessFile file;
  final int length;
  int _bytesRead = 0;
  int _nodes = 0;

  void node() {
    if (++_nodes > 4096) throw const FormatException('Too many tag blocks');
  }

  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 ||
        count < 0 ||
        offset + count > length ||
        (_bytesRead += count) > EmbeddedArtwork._maxTagBytes) {
      throw const FormatException('Artwork read limit');
    }
    await file.setPosition(offset);
    final bytes = await file.read(count);
    if (bytes.length != count) throw const FormatException('Truncated tag');
    return bytes;
  }

  Future<_Picture?> id3(int start, int end) async {
    if (end - start < 10) return null;
    final head = await read(start, 10);
    if (_text(head, 0, 3) != 'ID3') return null;
    final version = head[3];
    if (version < 2 || version > 4 || (version == 2 && (head[5] & 0x40) != 0)) {
      return null;
    }
    final size = _synchsafe(head, 6);
    var offset = start + 10;
    if (offset + size > end) return null;
    end = offset + size;
    _Read source = read;
    final unsynchronized = head[5] & 0x80 != 0;
    if (unsynchronized && version < 4) {
      final body = _unsynchronize(await read(offset, size));
      offset = 0;
      end = body.length;
      source = (at, count) async {
        if (at < 0 || count < 0 || at + count > body.length) {
          throw const FormatException('Truncated unsynchronized tag');
        }
        return Uint8List.sublistView(body, at, at + count);
      };
    }
    if (version >= 3 && head[5] & 0x40 != 0) {
      final extended = await source(offset, 4);
      final skip = version == 4
          ? _synchsafe(extended, 0)
          : _u32(extended, 0) + 4;
      if (skip < 4 || offset + skip > end) return null;
      offset += skip;
    }
    _Picture? fallback;
    final headerSize = version == 2 ? 6 : 10;
    while (offset + headerSize <= end) {
      node();
      final header = await source(offset, headerSize);
      final id = _text(header, 0, version == 2 ? 3 : 4);
      final frameSize = version == 2
          ? (header[3] << 16) | (header[4] << 8) | header[5]
          : version == 4
          ? _synchsafe(header, 4)
          : _u32(header, 4);
      offset += headerSize;
      if (frameSize <= 0 || offset + frameSize > end) break;
      final flags = version == 2 ? 0 : header[9];
      final unsupported = version == 3 ? flags & 0xC0 != 0 : flags & 0x0C != 0;
      if ((id == 'APIC' || id == 'PIC') &&
          !unsupported &&
          frameSize <= EmbeddedArtwork._maxFrameBytes) {
        var frame = await source(offset, frameSize);
        if (version == 4 && (unsynchronized || flags & 2 != 0)) {
          frame = _unsynchronize(frame);
        }
        var prefix =
            version == 3 && flags & 0x20 != 0 ||
                version == 4 && flags & 0x40 != 0
            ? 1
            : 0;
        if (version == 4 && flags & 1 != 0) prefix += 4;
        if (prefix < frame.length) {
          final picture = _id3Picture(
            Uint8List.sublistView(frame, prefix),
            version,
          );
          if (picture?.type == 3) return picture;
          fallback ??= picture;
        }
      }
      offset += frameSize;
    }
    return fallback;
  }

  Future<_Picture?> flac() async {
    var offset = 4;
    _Picture? fallback;
    while (offset + 4 <= length) {
      node();
      final header = await read(offset, 4);
      final size = (header[1] << 16) | (header[2] << 8) | header[3];
      offset += 4;
      if (offset + size > length) break;
      if (header[0] & 0x7F == 6 && size <= EmbeddedArtwork._maxFrameBytes) {
        final picture = _flacPicture(await read(offset, size));
        if (picture?.type == 3) return picture;
        fallback ??= picture;
      }
      if (header[0] & 0x80 != 0) break;
      offset += size;
    }
    return fallback;
  }

  Future<_Picture?> mp4(
    int start,
    int end,
    int depth, {
    bool cover = false,
  }) async {
    if (depth > 8) return null;
    var offset = start;
    while (offset + 8 <= end) {
      node();
      final header = await read(offset, 8);
      var size = _u32(header, 0);
      final type = _text(header, 4, 4);
      var headerSize = 8;
      if (size == 1) {
        final wide = await read(offset + 8, 8);
        size = (_u32(wide, 0) << 32) | _u32(wide, 4);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || offset + size > end) break;
      final body = offset + headerSize;
      if (cover &&
          type == 'data' &&
          size - headerSize > 8 &&
          size - headerSize - 8 <= EmbeddedArtwork.maxImageBytes) {
        final picture = _picture(
          await read(body + 8, size - headerSize - 8),
          3,
        );
        if (picture != null) return picture;
      } else if (const {
        'moov',
        'udta',
        'meta',
        'ilst',
        'covr',
      }.contains(type)) {
        final picture = await mp4(
          body + (type == 'meta' ? 4 : 0),
          offset + size,
          depth + 1,
          cover: type == 'covr',
        );
        if (picture != null) return picture;
      }
      offset += size;
    }
    return null;
  }

  Future<_Picture?> chunked(bool littleEndian) async {
    var offset = 12;
    while (offset + 8 <= length) {
      node();
      final header = await read(offset, 8);
      final size = _u32(header, 4, littleEndian: littleEndian);
      if (offset + 8 + size > length) break;
      if (_text(header, 0, 4).toLowerCase() == 'id3 ') {
        final picture = await id3(offset + 8, offset + 8 + size);
        if (picture != null) return picture;
      }
      offset += 8 + size + size % 2;
    }
    return null;
  }

  Future<_Picture?> ogg() async {
    var offset = 0;
    final packet = BytesBuilder(copy: false);
    int? serial;
    var packets = 0;
    while (offset + 27 <= length && packets < 3) {
      node();
      final header = await read(offset, 27);
      if (_text(header, 0, 4) != 'OggS' || header[4] != 0) return null;
      serial ??= _u32(header, 14, littleEndian: true);
      final segments = await read(offset + 27, header[26]);
      final payloadSize = segments.fold<int>(0, (sum, size) => sum + size);
      final payloadStart = offset + 27 + segments.length;
      if (_u32(header, 14, littleEndian: true) == serial) {
        final data = await read(payloadStart, payloadSize);
        var at = 0;
        for (final size in segments) {
          packet.add(Uint8List.sublistView(data, at, at + size));
          at += size;
          if (packet.length > EmbeddedArtwork._maxTagBytes) return null;
          if (size < 255) {
            final bytes = packet.takeBytes();
            packets++;
            final commentStart = _text(bytes, 0, 8) == 'OpusTags'
                ? 8
                : bytes.isNotEmpty &&
                      bytes[0] == 3 &&
                      _text(bytes, 1, 6) == 'vorbis'
                ? 7
                : null;
            if (commentStart != null) {
              return _commentPicture(bytes, commentStart);
            }
          }
        }
      }
      offset = payloadStart + payloadSize;
    }
    return null;
  }
}

_Picture? _commentPicture(Uint8List bytes, int offset) {
  offset += 4 + _u32(bytes, offset, littleEndian: true);
  final count = _u32(bytes, offset, littleEndian: true);
  offset += 4;
  _Picture? fallback;
  for (var i = 0; i < count && i < 4096; i++) {
    final size = _u32(bytes, offset, littleEndian: true);
    offset += 4;
    if (offset + size > bytes.length) return fallback;
    const key = 'METADATA_BLOCK_PICTURE=';
    if (size >= key.length &&
        _text(bytes, offset, key.length).toUpperCase() == key) {
      try {
        final encoded = _text(
          bytes,
          offset + key.length,
          size - key.length,
        ).replaceAll(RegExp(r'\s+'), '');
        final picture = encoded.isEmpty
            ? null
            : _flacPicture(base64Decode(encoded));
        if (picture?.type == 3) return picture;
        fallback ??= picture;
      } on FormatException {
        // One malformed comment must not hide a later valid picture.
      }
    }
    offset += size;
  }
  return fallback;
}

_Picture? _id3Picture(Uint8List frame, int version) {
  if (frame.length < 6 || frame[0] > 3) return null;
  var offset = version == 2 ? 4 : frame.indexOf(0, 1) + 1;
  if (offset <= 1 || offset >= frame.length) return null;
  final type = frame[offset++];
  final wide = frame[0] == 1 || frame[0] == 2;
  while (offset + (wide ? 1 : 0) < frame.length) {
    if (frame[offset] == 0 && (!wide || frame[offset + 1] == 0)) {
      offset += wide ? 2 : 1;
      return _picture(Uint8List.sublistView(frame, offset), type);
    }
    offset += wide ? 2 : 1;
  }
  return null;
}

_Picture? _flacPicture(Uint8List bytes) {
  if (bytes.length < 32) return null;
  final type = _u32(bytes, 0);
  var offset = 8 + _u32(bytes, 4);
  if (offset + 4 > bytes.length) return null;
  offset += 4 + _u32(bytes, offset) + 16;
  if (offset + 4 > bytes.length) return null;
  final size = _u32(bytes, offset);
  offset += 4;
  if (offset + size > bytes.length) return null;
  return _picture(Uint8List.sublistView(bytes, offset, offset + size), type);
}

_Picture? _picture(Uint8List bytes, int type) {
  if (bytes.length < 12 || bytes.length > EmbeddedArtwork.maxImageBytes) {
    return null;
  }
  final supported =
      bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF ||
      bytes[0] == 0x89 && _text(bytes, 1, 3) == 'PNG' ||
      _text(bytes, 0, 4) == 'RIFF' && _text(bytes, 8, 4) == 'WEBP';
  return supported ? _Picture(Uint8List.fromList(bytes), type) : null;
}

Uint8List _unsynchronize(Uint8List bytes) {
  final result = Uint8List(bytes.length);
  var end = 0;
  for (var i = 0; i < bytes.length; i++) {
    result[end++] = bytes[i];
    if (bytes[i] == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0) i++;
  }
  return Uint8List.sublistView(result, 0, end);
}

String _text(Uint8List bytes, int offset, int count) =>
    offset < 0 || offset + count > bytes.length
    ? ''
    : latin1.decode(Uint8List.sublistView(bytes, offset, offset + count));
int _u32(Uint8List bytes, int offset, {bool littleEndian = false}) =>
    ByteData.sublistView(
      bytes,
    ).getUint32(offset, littleEndian ? Endian.little : Endian.big);
int _synchsafe(Uint8List bytes, int offset) =>
    ((bytes[offset] & 127) << 21) |
    ((bytes[offset + 1] & 127) << 14) |
    ((bytes[offset + 2] & 127) << 7) |
    (bytes[offset + 3] & 127);
