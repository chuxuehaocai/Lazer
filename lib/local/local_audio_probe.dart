// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Tags read from a local file. Missing fields are filled from the file name,
/// so every track has a title the library can show.
class LocalAudioMetadata {
  const LocalAudioMetadata({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
  });

  final String title;
  final String artist;
  final String album;
  final Duration duration;
}

/// Reads the handful of tags the library needs without a native tag library.
///
/// MP3 (ID3v2.2/2.3/2.4), FLAC (STREAMINFO + VORBIS_COMMENT), M4A/MP4
/// (`mvhd` + `ilst`) and WAV (`fmt `/`data`) are parsed; anything else falls
/// back to the file name. Embedded artwork is deliberately ignored — the
/// library keeps the existing generative covers.
class LocalAudioProbe {
  const LocalAudioProbe();

  static const int _maxTextFrameBytes = 64 * 1024;

  Future<LocalAudioMetadata> probe(File file) async {
    final String path = file.path;
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final int length = await raf.length();
      if (length <= 0) return LocalAudioProbe.fromFileName(path);
      final Uint8List head = await _read(raf, 0, math.min(length, 12));
      if (_ascii(head, 0, 4) == 'fLaC') {
        return await _flac(raf, length, path);
      }
      if (head.length >= 3 && _ascii(head, 0, 3) == 'ID3') {
        return await _mp3(raf, length, path);
      }
      if (head.length >= 4 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
        return await _mp3(raf, length, path);
      }
      if (head.length >= 12 &&
          _ascii(head, 0, 4) == 'RIFF' &&
          _ascii(head, 8, 4) == 'WAVE') {
        return await _wav(raf, length, path);
      }
      if (head.length >= 8 && _ascii(head, 4, 4) == 'ftyp') {
        return await _mp4(raf, length, path);
      }
    } catch (_) {
      // A truncated or locked file is still listed with its file name.
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
    return LocalAudioProbe.fromFileName(path);
  }

  /// `歌手 - 标题` becomes artist/title; the parent folder becomes the album.
  static LocalAudioMetadata fromFileName(String path) {
    final String base = _baseName(path);
    String title = base;
    String artist = '';
    final int separator = base.indexOf(' - ');
    if (separator > 0) {
      artist = base.substring(0, separator).trim();
      title = base.substring(separator + 3).trim();
    } else if (base.contains('-')) {
      final int dash = base.indexOf('-');
      if (dash > 0) {
        artist = base.substring(0, dash).trim();
        title = base.substring(dash + 1).trim();
      }
    }
    if (title.isEmpty) title = '未命名';
    return LocalAudioMetadata(
      title: title,
      artist: artist,
      album: _parentName(path),
      duration: Duration.zero,
    );
  }

  Future<LocalAudioMetadata> _mp3(
    RandomAccessFile raf,
    int length,
    String path,
  ) async {
    final Map<String, String> tags = <String, String>{};
    int audioStart = 0;
    final Uint8List header = await _read(raf, 0, math.min(length, 10));
    if (header.length >= 10 && _ascii(header, 0, 3) == 'ID3') {
      final int major = header[3];
      final int flags = header[5];
      final int size = _syncSafe(header, 6);
      final int tagLength = math.min(size, length - 10);
      if (tagLength > 0) {
        await _readId3Frames(raf, tagLength, major, tags);
      }
      audioStart = 10 + size;
      if (major >= 4 && flags & 0x10 != 0) audioStart += 10;
      audioStart = math.min(audioStart, length);
    }
    Duration duration = Duration.zero;
    final String? lengthText = tags['lengthMs'];
    if (lengthText != null) {
      final int? milliseconds = int.tryParse(lengthText.trim());
      if (milliseconds != null && milliseconds > 0) {
        duration = Duration(milliseconds: milliseconds);
      }
    }
    duration = duration > Duration.zero
        ? duration
        : await _mpegDuration(raf, audioStart, length);
    return LocalAudioMetadata(
      title: _first(tags['title'], path),
      artist: tags['artist']?.trim() ?? '',
      album: tags['album']?.trim() ?? _parentName(path),
      duration: duration,
    );
  }

  Future<void> _readId3Frames(
    RandomAccessFile raf,
    int bodyLength,
    int major,
    Map<String, String> tags,
  ) async {
    int offset = 0;
    final bool isV22 = major == 2;
    final int headerLength = isV22 ? 6 : 10;
    while (offset + headerLength <= bodyLength) {
      final Uint8List header = await _read(raf, 10 + offset, headerLength);
      if (header.length != headerLength) break;
      final String id = _ascii(header, 0, isV22 ? 3 : 4);
      final int size = isV22
          ? (header[3] << 16) | (header[4] << 8) | header[5]
          : major == 4
          ? _syncSafe(header, 4)
          : _u32be(header, 4);
      if (id.trim().isEmpty || size <= 0 || offset + headerLength + size > bodyLength) {
        break;
      }
      if (_isTextFrame(id) && size <= _maxTextFrameBytes) {
        final Uint8List frame = await _read(
          raf,
          10 + offset + headerLength,
          size,
        );
        if (frame.length != size) break;
        _storeFrame(id, frame, tags);
      }
      offset += headerLength + size;
    }
  }

  bool _isTextFrame(String id) =>
      id == 'TIT2' ||
      id == 'TT2' ||
      id == 'TPE1' ||
      id == 'TP1' ||
      id == 'TALB' ||
      id == 'TAL' ||
      id == 'TLEN' ||
      id == 'TLE';

  void _storeFrame(String id, Uint8List frame, Map<String, String> tags) {
    if (frame.isEmpty || !_isTextFrame(id)) return;
    final String text = _decodeText(frame, frame[0]);
    if (text.isEmpty) return;
    switch (id) {
      case 'TIT2':
      case 'TT2':
        tags['title'] = text;
      case 'TPE1':
      case 'TP1':
        tags['artist'] = text;
      case 'TALB':
      case 'TAL':
        tags['album'] = text;
      case 'TLEN':
      case 'TLE':
        tags['lengthMs'] = text;
    }
  }

  Future<Duration> _mpegDuration(
    RandomAccessFile raf,
    int start,
    int fileLength,
  ) async {
    if (start >= fileLength) return Duration.zero;
    final int chunkLength = math.min(fileLength - start, 256 * 1024);
    final Uint8List chunk = await _read(raf, start, chunkLength);
    int frameOffset = -1;
    _MpegFrame? frame;
    for (int index = 0; index + 4 <= chunk.length; index++) {
      if (chunk[index] != 0xFF || (chunk[index + 1] & 0xE0) != 0xE0) continue;
      frame = _MpegFrame.parse(chunk, index);
      if (frame != null) {
        frameOffset = index;
        break;
      }
    }
    if (frame == null || frameOffset < 0) return Duration.zero;
    final int sideInfo = frame.version == 1
        ? (frame.mono ? 17 : 32)
        : (frame.mono ? 9 : 17);
    final int xing = frameOffset + 4 + sideInfo;
    if (xing + 12 <= chunk.length) {
      final String marker = _ascii(chunk, xing, 4);
      if (marker == 'Xing' || marker == 'Info') {
        final int frames = _u32be(chunk, xing + 8);
        if (frames > 0) {
          return Duration(
            milliseconds:
                (frames * frame.samplesPerFrame * 1000 / frame.sampleRate)
                    .round(),
          );
        }
      }
    }
    if (frame.bitrate > 0) {
      final double seconds =
          (fileLength - start - frameOffset) * 8 / frame.bitrate;
      return Duration(milliseconds: (seconds * 1000).round());
    }
    return Duration.zero;
  }

  Future<LocalAudioMetadata> _flac(
    RandomAccessFile raf,
    int length,
    String path,
  ) async {
    int offset = 4;
    Uint8List? streamInfo;
    final Map<String, String> tags = <String, String>{};
    while (offset + 4 <= length) {
      final Uint8List header = await _read(raf, offset, 4);
      if (header.length < 4) break;
      final bool last = header[0] & 0x80 != 0;
      final int type = header[0] & 0x7F;
      final int size = (header[1] << 16) | (header[2] << 8) | header[3];
      if (offset + 4 + size > length) break;
      if (type == 0 && size >= 34) {
        streamInfo = await _read(raf, offset + 4, 34);
      } else if (type == 4 && size > 0) {
        tags.addAll(_parseVorbisComment(await _read(raf, offset + 4, size)));
      }
      offset += 4 + size;
      if (last) break;
    }
    Duration duration = Duration.zero;
    if (streamInfo != null && streamInfo.length >= 18) {
      final int sampleRate = (streamInfo[10] << 12) |
          (streamInfo[11] << 4) |
          (streamInfo[12] >> 4);
      final int totalSamples = ((streamInfo[13] & 0x0F) << 32) |
          (streamInfo[14] << 24) |
          (streamInfo[15] << 16) |
          (streamInfo[16] << 8) |
          streamInfo[17];
      if (sampleRate > 0 && totalSamples > 0) {
        duration = Duration(
          milliseconds: (totalSamples * 1000 / sampleRate).round(),
        );
      }
    }
    return LocalAudioMetadata(
      title: _first(tags['TITLE'], path),
      artist: tags['ARTIST']?.trim() ?? '',
      album: tags['ALBUM']?.trim() ?? _parentName(path),
      duration: duration,
    );
  }

  Map<String, String> _parseVorbisComment(Uint8List block) {
    final Map<String, String> tags = <String, String>{};
    try {
      int offset = 0;
      if (offset + 4 > block.length) return tags;
      final int vendorLength = _u32le(block, offset);
      offset += 4 + vendorLength;
      if (offset + 4 > block.length) return tags;
      final int count = _u32le(block, offset);
      offset += 4;
      for (int index = 0; index < count; index++) {
        if (offset + 4 > block.length) break;
        final int size = _u32le(block, offset);
        offset += 4;
        if (size <= 0 || offset + size > block.length) break;
        final String entry = utf8.decode(
          Uint8List.sublistView(block, offset, offset + size),
          allowMalformed: true,
        );
        offset += size;
        final int equals = entry.indexOf('=');
        if (equals <= 0) continue;
        tags[entry.substring(0, equals).toUpperCase()] = entry
            .substring(equals + 1)
            .trim();
      }
    } catch (_) {}
    return tags;
  }

  Future<LocalAudioMetadata> _mp4(
    RandomAccessFile raf,
    int length,
    String path,
  ) async {
    Duration duration = Duration.zero;
    final Map<String, String> tags = <String, String>{};
    try {
      final _Atom? moov = await _findAtom(raf, 0, length, 'moov');
      if (moov != null) {
        final _Atom? mvhd = await _findAtom(
          raf,
          moov.contentStart,
          moov.end,
          'mvhd',
        );
        if (mvhd != null) {
          final Uint8List data = await _read(
            raf,
            mvhd.contentStart,
            math.min(mvhd.end - mvhd.contentStart, 32),
          );
          if (data.length >= 20) {
            final bool v1 = data[0] == 1;
            final int timescale = v1
                ? _u32be(data, 20)
                : _u32be(data, 12);
            final int units = v1 && data.length >= 32
                ? (_u32be(data, 24) << 32) | _u32be(data, 28)
                : _u32be(data, 16);
            if (timescale > 0 && units > 0) {
              duration = Duration(
                milliseconds: (units * 1000 / timescale).round(),
              );
            }
          }
        }
        final _Atom? udta = await _findAtom(
          raf,
          moov.contentStart,
          moov.end,
          'udta',
        );
        if (udta != null) {
          final _Atom? meta = await _findAtom(
            raf,
            udta.contentStart,
            udta.end,
            'meta',
          );
          if (meta != null) {
            final _Atom? ilst = await _findAtom(
              raf,
              meta.contentStart + 4,
              meta.end,
              'ilst',
            );
            if (ilst != null) {
              int offset = ilst.contentStart;
              while (offset + 8 <= ilst.end) {
                final Uint8List head = await _read(raf, offset, 8);
                if (head.length < 8) break;
                final int size = _u32be(head, 0);
                final String name = _ascii(head, 4, 4);
                if (size < 8 || offset + size > ilst.end) break;
                final _Atom? data = await _findAtom(
                  raf,
                  offset + 8,
                  offset + size,
                  'data',
                );
                if (data != null) {
                  final int payloadStart = data.contentStart + 8;
                  if (payloadStart < data.end) {
                    final Uint8List payload = await _read(
                      raf,
                      payloadStart,
                      data.end - payloadStart,
                    );
                    final String text = utf8
                        .decode(payload, allowMalformed: true)
                        .replaceAll(' ', '')
                        .trim();
                    if (text.isNotEmpty) {
                      tags[switch (name) {
                        '©nam' => 'title',
                        '©ART' || 'aART' => 'artist',
                        '©alb' => 'album',
                        _ => name,
                      }] = text;
                    }
                  }
                }
                offset += size;
              }
            }
          }
        }
      }
    } catch (_) {}
    return LocalAudioMetadata(
      title: _first(tags['title'], path),
      artist: tags['artist']?.trim() ?? '',
      album: tags['album']?.trim() ?? _parentName(path),
      duration: duration,
    );
  }

  Future<LocalAudioMetadata> _wav(
    RandomAccessFile raf,
    int length,
    String path,
  ) async {
    int offset = 12;
    int byteRate = 0;
    int dataSize = 0;
    while (offset + 8 <= length) {
      final Uint8List head = await _read(raf, offset, 8);
      if (head.length < 8) break;
      final String id = _ascii(head, 0, 4);
      final int size = _u32le(head, 4);
      if (id == 'fmt ') {
        final Uint8List format = await _read(
          raf,
          offset + 8,
          math.min(size, 16),
        );
        if (format.length >= 12) byteRate = _u32le(format, 8);
      } else if (id == 'data') {
        dataSize = size;
        break;
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    Duration duration = Duration.zero;
    if (byteRate > 0 && dataSize > 0) {
      duration = Duration(milliseconds: (dataSize * 1000 / byteRate).round());
    }
    return LocalAudioMetadata(
      title: _baseName(path),
      artist: '',
      album: _parentName(path),
      duration: duration,
    );
  }

  Future<_Atom?> _findAtom(
    RandomAccessFile raf,
    int start,
    int end,
    String type,
  ) async {
    int offset = start;
    while (offset + 8 <= end) {
      final Uint8List head = await _read(raf, offset, 8);
      if (head.length < 8) return null;
      int size = _u32be(head, 0);
      final String name = _ascii(head, 4, 4);
      int headerSize = 8;
      if (size == 1) {
        final Uint8List extended = await _read(raf, offset + 8, 8);
        if (extended.length < 8) return null;
        size = (_u32be(extended, 0) << 32) | _u32be(extended, 4);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || offset + size > end) return null;
      if (name == type) {
        return _Atom(
          contentStart: offset + headerSize,
          end: offset + size,
        );
      }
      offset += size;
    }
    return null;
  }
}

class _Atom {
  const _Atom({required this.contentStart, required this.end});
  final int contentStart;
  final int end;
}

class _MpegFrame {
  _MpegFrame({
    required this.version,
    required this.bitrate,
    required this.sampleRate,
    required this.samplesPerFrame,
    required this.mono,
  });

  /// 1, 2 or 25 (MPEG 2.5).
  final int version;
  final int bitrate;
  final int sampleRate;
  final int samplesPerFrame;
  final bool mono;

  static _MpegFrame? parse(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return null;
    final int first = bytes[offset];
    final int second = bytes[offset + 1];
    final int third = bytes[offset + 2];
    if (first != 0xFF || (second & 0xE0) != 0xE0) return null;
    final int versionBits = (second >> 3) & 0x03;
    final int layerBits = (second >> 1) & 0x03;
    final int bitrateIndex = (third >> 4) & 0x0F;
    final int sampleIndex = (third >> 2) & 0x03;
    if (versionBits == 1 || layerBits == 0) return null;
    if (bitrateIndex == 0 || bitrateIndex == 15 || sampleIndex == 3) {
      return null;
    }
    final int version = switch (versionBits) {
      0 => 25,
      2 => 2,
      _ => 1,
    };
    final int layer = switch (layerBits) {
      1 => 3,
      2 => 2,
      _ => 1,
    };
    final int bitrate = _bitrate(version, layer, bitrateIndex);
    final int sampleRate = _sampleRate(version, sampleIndex);
    if (bitrate <= 0 || sampleRate <= 0) return null;
    final int samplesPerFrame = layer == 1
        ? 384
        : layer == 2
        ? 1152
        : version == 1
        ? 1152
        : 576;
    return _MpegFrame(
      version: version,
      bitrate: bitrate,
      sampleRate: sampleRate,
      samplesPerFrame: samplesPerFrame,
      mono: (bytes[offset + 3] >> 6) == 3,
    );
  }

  static int _bitrate(int version, int layer, int index) {
    const List<int> layer1V1 = <int>[
      0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448,
    ];
    const List<int> layer2V1 = <int>[
      0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384,
    ];
    const List<int> layer3V1 = <int>[
      0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ];
    const List<int> layer1V2 = <int>[
      0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256,
    ];
    const List<int> layer23V2 = <int>[
      0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
    ];
    final List<int> table;
    if (version == 1) {
      table = layer == 1
          ? layer1V1
          : layer == 2
          ? layer2V1
          : layer3V1;
    } else {
      table = layer == 1 ? layer1V2 : layer23V2;
    }
    return table[index] * 1000;
  }

  static int _sampleRate(int version, int index) {
    const List<int> mpeg1 = <int>[44100, 48000, 32000];
    const List<int> mpeg2 = <int>[22050, 24000, 16000];
    const List<int> mpeg25 = <int>[11025, 12000, 8000];
    return switch (version) {
      1 => mpeg1[index],
      2 => mpeg2[index],
      _ => mpeg25[index],
    };
  }
}

Future<Uint8List> _read(RandomAccessFile raf, int offset, int length) async {
  if (length <= 0) return Uint8List(0);
  await raf.setPosition(offset);
  return raf.read(length);
}

String _ascii(Uint8List bytes, int offset, int length) {
  if (offset < 0 || offset + length > bytes.length) return '';
  return String.fromCharCodes(bytes.sublist(offset, offset + length));
}

int _u32be(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _u32le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _syncSafe(Uint8List bytes, int offset) =>
    ((bytes[offset] & 0x7F) << 21) |
    ((bytes[offset + 1] & 0x7F) << 14) |
    ((bytes[offset + 2] & 0x7F) << 7) |
    (bytes[offset + 3] & 0x7F);

String _decodeText(Uint8List frame, int encoding) {
  Uint8List data = Uint8List.sublistView(frame, 1);
  int end = data.length;
  while (end > 0 && data[end - 1] == 0) {
    end--;
  }
  data = Uint8List.sublistView(data, 0, end);
  String text;
  switch (encoding) {
    case 0:
      text = latin1.decode(data, allowInvalid: true);
    case 1:
      if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
        text = _utf16(data, 2, little: true);
      } else if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
        text = _utf16(data, 2, little: false);
      } else {
        text = _utf16(data, 0, little: true);
      }
    case 2:
      text = _utf16(data, 0, little: false);
    default:
      text = utf8.decode(data, allowMalformed: true);
  }
  return text.replaceAll(' ', '').trim();
}

String _utf16(Uint8List bytes, int offset, {required bool little}) {
  final List<int> units = <int>[];
  for (int index = offset; index + 1 < bytes.length; index += 2) {
    units.add(
      little
          ? bytes[index] | (bytes[index + 1] << 8)
          : (bytes[index] << 8) | bytes[index + 1],
    );
  }
  return String.fromCharCodes(units);
}

String _first(String? value, String path) {
  final String trimmed = value?.trim() ?? '';
  if (trimmed.isNotEmpty) return trimmed;
  return LocalAudioProbe.fromFileName(path).title;
}

String _baseName(String path) {
  final String normalized = path.replaceAll('\\', '/');
  final String name = normalized.split('/').last;
  final int dot = name.lastIndexOf('.');
  final String base = dot > 0 ? name.substring(0, dot) : name;
  return base.trim().isEmpty ? name : base;
}

String _parentName(String path) {
  final String normalized = path.replaceAll('\\', '/');
  final List<String> parts = normalized.split('/')
    ..removeWhere((String part) => part.isEmpty);
  if (parts.length < 2) return '';
  final String parent = parts[parts.length - 2];
  return parent.contains(':') ? '' : parent;
}
