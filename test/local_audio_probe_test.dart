import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/local/local_audio_probe.dart';

List<int> _be32(int value) => <int>[
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

List<int> _le32(int value) => <int>[
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

List<int> _syncSafe(int value) => <int>[
  (value >> 21) & 0x7F,
  (value >> 14) & 0x7F,
  (value >> 7) & 0x7F,
  value & 0x7F,
];

List<int> _id3v23Frame(String id, Uint8List payload) => <int>[
  ...ascii.encode(id),
  ..._be32(payload.length),
  0,
  0,
  ...payload,
];

Uint8List _utf8Text(String text) =>
    Uint8List.fromList(<int>[3, ...utf8.encode(text)]);

Uint8List _utf16Text(String text) {
  final List<int> bytes = <int>[1, 0xFF, 0xFE];
  for (final int unit in text.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return Uint8List.fromList(bytes);
}

Uint8List _id3Tag(List<List<int>> frames) {
  final List<int> body = <int>[for (final List<int> frame in frames) ...frame];
  return Uint8List.fromList(<int>[
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    ..._syncSafe(body.length),
    ...body,
  ]);
}

class _CountingFile implements File {
  _CountingFile(this.delegate, this.maxRead);

  final File delegate;
  final void Function(int bytes) maxRead;

  @override
  String get path => delegate.path;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _CountingRandomAccessFile(await delegate.open(mode: mode), maxRead);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingRandomAccessFile implements RandomAccessFile {
  _CountingRandomAccessFile(this.delegate, this.maxRead);

  final RandomAccessFile delegate;
  final void Function(int bytes) maxRead;

  @override
  Future<int> length() => delegate.length();

  @override
  Future<Uint8List> read(int bytes) {
    maxRead(bytes);
    return delegate.read(bytes);
  }

  @override
  Future<RandomAccessFile> setPosition(int position) =>
      delegate.setPosition(position);

  @override
  Future<void> close() => delegate.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<int> _mpegFrameWithXing(int frameCount) {
  final List<int> frame = <int>[0xFF, 0xFB, 0x90, 0x00];
  frame.addAll(List<int>.filled(32, 0));
  frame.addAll(ascii.encode('Xing'));
  frame.addAll(_be32(0));
  frame.addAll(_be32(frameCount));
  frame.addAll(List<int>.filled(64, 0));
  return frame;
}

List<int> _atom(String type, List<int> content) => <int>[
  ..._be32(8 + content.length),
  ...latin1.encode(type),
  ...content,
];

const List<int> _embeddedPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x00,
  0x03,
  0x00,
  0x01,
  0x00,
  0x05,
  0xFE,
  0x02,
  0xFE,
  0xDC,
  0xCC,
  0x59,
  0xE7,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

const List<int> _embeddedJpeg = <int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0x00,
  0x10,
  0x4A,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
  0x01,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x00,
];

List<int> _unsync(List<int> bytes) {
  final List<int> encoded = <int>[];
  for (final int byte in bytes) {
    encoded.add(byte);
    if (byte == 0xFF) encoded.add(0);
  }
  return encoded;
}

Uint8List _apic(
  List<int> image, {
  int type = 3,
  String mime = 'image/png',
  int encoding = 0,
  List<int> description = const <int>[0],
}) => Uint8List.fromList(<int>[
  encoding,
  ...latin1.encode(mime),
  0,
  type,
  ...description,
  ...image,
]);

List<int> _id3v22Frame(String id, List<int> payload) => <int>[
  ...ascii.encode(id),
  (payload.length >> 16) & 0xFF,
  (payload.length >> 8) & 0xFF,
  payload.length & 0xFF,
  ...payload,
];

Uint8List _id3TagWith(
  List<List<int>> frames, {
  int major = 3,
  int flags = 0,
  bool unsynchronised = false,
}) {
  final List<int> logical = <int>[
    for (final List<int> frame in frames) ...frame,
  ];
  final List<int> body = unsynchronised ? _unsync(logical) : logical;
  return Uint8List.fromList(<int>[
    ...ascii.encode('ID3'),
    major,
    0,
    flags,
    ..._syncSafe(body.length),
    ...body,
  ]);
}

List<int> _flacPicture(List<int> image, {int type = 3}) {
  final List<int> mime = ascii.encode('image/png');
  return <int>[
    ..._be32(type),
    ..._be32(mime.length),
    ...mime,
    ..._be32(0),
    ..._be32(1),
    ..._be32(1),
    ..._be32(8),
    ..._be32(0),
    ..._be32(image.length),
    ...image,
  ];
}

List<int> _oggPage(List<int> packet) {
  final List<int> segments = <int>[];
  int remaining = packet.length;
  do {
    final int size = remaining > 255 ? 255 : remaining;
    segments.add(size);
    remaining -= size;
  } while (remaining > 0);
  return <int>[
    ...ascii.encode('OggS'),
    0,
    0,
    ...List<int>.filled(8, 0),
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    segments.length,
    ...segments,
    ...packet,
  ];
}

Future<Uint8List> _cachedArtwork(Directory root, File audio) async {
  final Directory cache = Directory('${root.path}/artwork-cache');
  final String? uri = await LocalAudioProbe.artworkUriFor(
    audio.path,
    cacheDirectory: cache,
  );
  expect(uri, isNotNull);
  return File.fromUri(Uri.parse(uri!)).readAsBytes();
}

void main() {
  late Directory root;
  const LocalAudioProbe probe = LocalAudioProbe();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-probe-test-');
  });
  tearDown(() async => root.delete(recursive: true));

  Future<File> write(String name, List<int> bytes) async {
    final File file = File('${root.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  test('reads ID3v2.3 tags and the Xing frame count', () async {
    final File file = await write('tagged.mp3', <int>[
      ..._id3Tag(<List<int>>[
        _id3v23Frame('TIT2', _utf8Text('夜に駆ける')),
        _id3v23Frame('TPE1', _utf8Text('YOASOBI')),
        _id3v23Frame('TALB', _utf8Text('THE BOOK')),
        _id3v23Frame('TLEN', _utf8Text('261000')),
      ]),
      ..._mpegFrameWithXing(1000),
    ]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, '夜に駆ける');
    expect(metadata.artist, 'YOASOBI');
    expect(metadata.album, 'THE BOOK');
    expect(metadata.duration.inMilliseconds, 261000);
  });

  test(
    'skips large embedded artwork and reads following text frames',
    () async {
      final int imageBytes = 4 * 1024 * 1024;
      final File file = await write('artwork.mp3', <int>[
        ..._id3Tag(<List<int>>[
          _id3v23Frame(
            'APIC',
            Uint8List.fromList(List<int>.filled(imageBytes, 0xA5)),
          ),
          _id3v23Frame('TIT2', _utf8Text('Metadata after artwork')),
          _id3v23Frame('TPE1', _utf8Text('Scanner test')),
          _id3v23Frame('TLEN', _utf8Text('90000')),
        ]),
        ..._mpegFrameWithXing(1000),
      ]);
      int largestRead = 0;

      final LocalAudioMetadata metadata = await probe.probe(
        _CountingFile(file, (int bytes) {
          if (bytes > largestRead) largestRead = bytes;
        }),
      );

      expect(metadata.title, 'Metadata after artwork');
      expect(metadata.artist, 'Scanner test');
      expect(metadata.duration.inMilliseconds, 90000);
      expect(largestRead, lessThan(1024));
    },
  );

  test('decodes UTF-16 ID3 text', () async {
    final File file = await write('utf16.mp3', <int>[
      ..._id3Tag(<List<int>>[
        _id3v23Frame('TIT2', _utf16Text('日本語のタイトル')),
        _id3v23Frame('TPE1', _utf16Text('歌手')),
      ]),
      ..._mpegFrameWithXing(44100),
    ]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, '日本語のタイトル');
    expect(metadata.artist, '歌手');
    expect(metadata.duration.inSeconds, 1152);
  });

  test('reads FLAC STREAMINFO and Vorbis comments', () async {
    const int sampleRate = 44100;
    const int channels = 2;
    const int bitsPerSample = 16;
    const int totalSamples = 88200;
    final List<int> streamInfo = List<int>.filled(34, 0);
    streamInfo[10] = (sampleRate >> 12) & 0xFF;
    streamInfo[11] = (sampleRate >> 4) & 0xFF;
    streamInfo[12] =
        ((sampleRate & 0x0F) << 4) |
        ((channels - 1) << 1) |
        (((bitsPerSample - 1) >> 4) & 1);
    streamInfo[13] =
        (((bitsPerSample - 1) & 0x0F) << 4) | ((totalSamples >> 32) & 0x0F);
    streamInfo[14] = (totalSamples >> 24) & 0xFF;
    streamInfo[15] = (totalSamples >> 16) & 0xFF;
    streamInfo[16] = (totalSamples >> 8) & 0xFF;
    streamInfo[17] = totalSamples & 0xFF;

    final List<int> vendor = utf8.encode('lazer');
    final List<int> comments = <int>[
      ..._le32(vendor.length),
      ...vendor,
      ..._le32(3),
      for (final String entry in <String>[
        'TITLE=夜の歌',
        'ARTIST=音楽人',
        'ALBUM=アルバム',
      ]) ...<int>[..._le32(utf8.encode(entry).length), ...utf8.encode(entry)],
    ];
    final File file = await write('song.flac', <int>[
      ...ascii.encode('fLaC'),
      0x00,
      0x00,
      0x00,
      34,
      ...streamInfo,
      0x84,
      (comments.length >> 16) & 0xFF,
      (comments.length >> 8) & 0xFF,
      comments.length & 0xFF,
      ...comments,
    ]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, '夜の歌');
    expect(metadata.artist, '音楽人');
    expect(metadata.album, 'アルバム');
    expect(metadata.duration.inSeconds, 2);
  });

  test('reads MP4 mvhd duration and ilst tags', () async {
    final List<int> mvhd = <int>[
      0,
      0,
      0,
      0,
      ..._be32(0),
      ..._be32(0),
      ..._be32(1000),
      ..._be32(3000),
      ...List<int>.filled(80, 0),
    ];
    List<int> item(String name, String value) {
      final List<int> data = <int>[
        ..._be32(1),
        ..._be32(0),
        ...utf8.encode(value),
      ];
      return _atom(name, _atom('data', data));
    }

    final List<int> ilst = _atom('ilst', <int>[
      ...item('©nam', '夜の歌'),
      ...item('©ART', '音楽人'),
      ...item('©alb', 'アルバム'),
    ]);
    final List<int> meta = _atom('meta', <int>[0, 0, 0, 0, ...ilst]);
    final List<int> udta = _atom('udta', meta);
    final List<int> moov = _atom('moov', <int>[
      ..._atom('mvhd', mvhd),
      ...udta,
    ]);
    final File file = await write('song.m4a', <int>[
      ..._atom('ftyp', <int>[...ascii.encode('M4A '), 0, 0, 0, 0]),
      ..._atom('mdat', List<int>.filled(64, 0)),
      ...moov,
    ]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, '夜の歌');
    expect(metadata.artist, '音楽人');
    expect(metadata.album, 'アルバム');
    expect(metadata.duration.inSeconds, 3);
  });

  test('reads the WAV fmt and data chunks', () async {
    final File file = await write('song.wav', <int>[
      ...ascii.encode('RIFF'),
      ..._le32(36 + 1000),
      ...ascii.encode('WAVE'),
      ...ascii.encode('fmt '),
      ..._le32(16),
      1,
      0,
      2,
      0,
      ..._le32(44100),
      ..._le32(176400),
      4,
      0,
      16,
      0,
      ...ascii.encode('data'),
      ..._le32(176400),
      ...List<int>.filled(176400, 0),
    ]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, 'song');
    expect(metadata.duration.inSeconds, 1);
  });

  test('falls back to the file name and parent folder', () async {
    final File file = await write('Music/夜の歌/音楽人 - 夜に駆ける.ogg', <int>[
      0x4F,
      0x67,
      0x67,
      0x53,
    ]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, '夜に駆ける');
    expect(metadata.artist, '音楽人');
    expect(metadata.album, '夜の歌');
    expect(metadata.duration, Duration.zero);
  });

  test('tolerates a truncated header', () async {
    final File file = await write('broken.mp3', <int>[0x49, 0x44]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, 'broken');
  });

  test('reads an ID3 picture and the text frames around it', () async {
    final List<int> description = <int>[0xFF, 0xFE];
    for (final int unit in '封面'.codeUnits) {
      description
        ..add(unit & 0xFF)
        ..add((unit >> 8) & 0xFF);
    }
    description
      ..add(0)
      ..add(0);
    final File file = await write('tagged-cover.mp3', <int>[
      ..._id3Tag(<List<int>>[
        _id3v23Frame('TIT2', _utf8Text('带封面')),
        _id3v23Frame(
          'APIC',
          _apic(_embeddedPng, encoding: 1, description: description),
        ),
        _id3v23Frame('TPE1', _utf8Text('音乐人')),
      ]),
      ..._mpegFrameWithXing(1000),
    ]);
    final LocalAudioMetadata metadata = await probe.probe(file);
    expect(metadata.title, '带封面');
    expect(metadata.artist, '音乐人');
    expect(await _cachedArtwork(root, file), _embeddedPng);
  });

  test('prefers a front cover and falls back to another picture', () async {
    final File front = await write('front.mp3', <int>[
      ..._id3Tag(<List<int>>[
        _id3v23Frame('APIC', _apic(_embeddedJpeg, type: 0, mime: 'image/jpeg')),
        _id3v23Frame('APIC', _apic(_embeddedPng)),
      ]),
    ]);
    expect(await _cachedArtwork(root, front), _embeddedPng);

    final File other = await write('other.mp3', <int>[
      ..._id3Tag(<List<int>>[
        _id3v23Frame('APIC', _apic(_embeddedJpeg, type: 0, mime: 'image/jpeg')),
      ]),
    ]);
    expect(await _cachedArtwork(root, other), _embeddedJpeg);
  });

  test('decodes unsynchronised ID3v2.3 and v2.4 artwork', () async {
    final Uint8List payload = _apic(_embeddedJpeg, mime: 'image/jpeg');
    final File v23 = await write('unsync23.mp3', <int>[
      ..._id3TagWith(
        <List<int>>[_id3v23Frame('APIC', payload)],
        flags: 0x80,
        unsynchronised: true,
      ),
    ]);
    expect(await _cachedArtwork(root, v23), _embeddedJpeg);

    final List<int> stored = _unsync(payload);
    final File v24 = await write('unsync24.mp3', <int>[
      ..._id3TagWith(<List<int>>[
        <int>[
          ...ascii.encode('APIC'),
          ..._syncSafe(stored.length),
          0,
          0x02,
          ...stored,
        ],
      ], major: 4),
    ]);
    expect(await _cachedArtwork(root, v24), _embeddedJpeg);
  });

  test('reads an ID3v2.2 PIC frame', () async {
    final File file = await write('legacy.mp3', <int>[
      ..._id3TagWith(<List<int>>[
        _id3v22Frame('PIC', <int>[
          0,
          ...ascii.encode('PNG'),
          3,
          ...ascii.encode('cover'),
          0,
          ..._embeddedPng,
        ]),
      ], major: 2),
    ]);
    expect(await _cachedArtwork(root, file), _embeddedPng);
  });

  test('reads a FLAC picture block', () async {
    final List<int> picture = _flacPicture(_embeddedPng);
    final File file = await write('picture.flac', <int>[
      ...ascii.encode('fLaC'),
      0x86,
      (picture.length >> 16) & 0xFF,
      (picture.length >> 8) & 0xFF,
      picture.length & 0xFF,
      ...picture,
    ]);
    expect(await _cachedArtwork(root, file), _embeddedPng);
  });

  test('reads MP4 cover data without treating it as text', () async {
    List<int> text(String name, String value) {
      final List<int> data = <int>[
        ..._be32(1),
        ..._be32(0),
        ...utf8.encode(value),
      ];
      return _atom(name, _atom('data', data));
    }

    final List<int> cover = _atom(
      'covr',
      _atom('data', <int>[..._be32(0x0E), ..._be32(0), ..._embeddedPng]),
    );
    final List<int> ilst = _atom('ilst', <int>[
      ...text('\u00A9nam', '封面之后'),
      ...cover,
    ]);
    final File tagged = await write('cover.m4a', <int>[
      ..._atom('ftyp', <int>[...ascii.encode('M4A '), 0, 0, 0, 0]),
      ..._atom(
        'moov',
        _atom('udta', _atom('meta', <int>[0, 0, 0, 0, ...ilst])),
      ),
    ]);
    expect((await probe.probe(tagged)).title, '封面之后');
    expect(await _cachedArtwork(root, tagged), _embeddedPng);

    final List<int> image = List<int>.filled(4 * 1024 * 1024, 0xA5);
    final List<int> huge = _atom('ilst', <int>[
      ..._atom(
        'covr',
        _atom('data', <int>[..._be32(13), ..._be32(0), ...image]),
      ),
      ...text('\u00A9nam', 'After cover'),
      ...text('\u00A9ART', 'Scanner'),
    ]);
    final File bulky = await write('bulky.m4a', <int>[
      ..._atom('ftyp', <int>[...ascii.encode('M4A '), 0, 0, 0, 0]),
      ..._atom('mdat', List<int>.filled(32, 0)),
      ..._atom(
        'moov',
        _atom('udta', _atom('meta', <int>[0, 0, 0, 0, ...huge])),
      ),
    ]);
    int largestRead = 0;
    final LocalAudioMetadata metadata = await probe.probe(
      _CountingFile(bulky, (int bytes) {
        if (bytes > largestRead) largestRead = bytes;
      }),
    );
    expect(metadata.title, 'After cover');
    expect(metadata.artist, 'Scanner');
    expect(largestRead, lessThan(1024));
  });

  test('reads a Vorbis metadata block picture', () async {
    final String encoded = base64Encode(_flacPicture(_embeddedPng));
    final String wrapped =
        '${encoded.substring(0, 40)}\n${encoded.substring(40)}';
    final List<int> vendor = ascii.encode('lazer');
    final List<int> comment = utf8.encode('METADATA_BLOCK_PICTURE=$wrapped');
    final List<int> packet = <int>[
      3,
      ...ascii.encode('vorbis'),
      ..._le32(vendor.length),
      ...vendor,
      ..._le32(1),
      ..._le32(comment.length),
      ...comment,
    ];
    final File file = await write('picture.ogg', _oggPage(packet));
    expect(await _cachedArtwork(root, file), _embeddedPng);
  });

  test('reads artwork from a WAV ID3 chunk', () async {
    final Uint8List tag = _id3Tag(<List<int>>[
      _id3v23Frame('APIC', _apic(_embeddedPng)),
    ]);
    final File file = await write('picture.wav', <int>[
      ...ascii.encode('RIFF'),
      ..._le32(4 + 8 + tag.length),
      ...ascii.encode('WAVE'),
      ...ascii.encode('id3 '),
      ..._le32(tag.length),
      ...tag,
    ]);
    expect(await _cachedArtwork(root, file), _embeddedPng);
  });

  test('uses a sidecar only when the audio has no embedded picture', () async {
    final File bare = await write('plain.mp3', <int>[0x49, 0x44, 0x33]);
    await write('plain.png', _embeddedPng);
    final Directory cache = Directory('${root.path}/sidecar-cache');
    final String? sidecar = await LocalAudioProbe.artworkUriFor(
      bare.path,
      cacheDirectory: cache,
    );
    expect(sidecar, isNotNull);
    expect(sidecar, isNot(contains('sidecar-cache')));
    expect(await File.fromUri(Uri.parse(sidecar!)).readAsBytes(), _embeddedPng);

    await write('embedded.jpg', <int>[1, 2, 3, 4]);
    final File audio = await write('embedded.mp3', <int>[
      ..._id3Tag(<List<int>>[_id3v23Frame('APIC', _apic(_embeddedPng))]),
    ]);
    expect(await _cachedArtwork(root, audio), _embeddedPng);
  });
}
