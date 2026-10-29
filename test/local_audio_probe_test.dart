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

  test('skips large embedded artwork and reads following text frames', () async {
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
  });

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
    streamInfo[13] = (((bitsPerSample - 1) & 0x0F) << 4) |
        ((totalSamples >> 32) & 0x0F);
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
      ]) ...<int>[
        ..._le32(utf8.encode(entry).length),
        ...utf8.encode(entry),
      ],
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
      return _atom(name, _atom('data', data));    }

    final List<int> ilst = _atom('ilst', <int>[
      ...item('©nam', '夜の歌'),
      ...item('©ART', '音楽人'),
      ...item('©alb', 'アルバム'),
    ]);
    final List<int> meta = _atom('meta', <int>[
      0,
      0,
      0,
      0,
      ...ilst,
    ]);
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
    final File file = await write(
      'Music/夜の歌/音楽人 - 夜に駆ける.ogg',
      <int>[0x4F, 0x67, 0x67, 0x53],
    );
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
}
