import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/gateway/response_decoder.dart';
import 'package:lazer_nextgen/gateway/transport.dart';

class _Headers extends Fake implements io.HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  set contentType(io.ContentType? value) {}
  @override
  void forEach(void Function(String, List<String>) action) {}
}

class _Response extends Stream<List<int>> implements io.HttpClientResponse {
  _Response(String body) : bytes = utf8.encode(body);
  final List<int> bytes;
  @override
  int get statusCode => 200;
  @override
  final io.HttpHeaders headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements io.HttpClientRequest {
  _Request(this.body);
  final String body;
  @override
  final io.HttpHeaders headers = _Headers();
  @override
  void write(Object? object) {}
  @override
  Future<io.HttpClientResponse> close() async => _Response(body);
}

class _Client extends Fake implements io.HttpClient {
  _Client(this.body);
  final String body;
  @override
  Future<io.HttpClientRequest> postUrl(Uri url) async => _Request(body);
}

void main() {
  test('transport preserves normalized bodies and protocol failures', () async {
    final body = jsonEncode({
      'code': '200',
      'playlist': {
        'tracks': [
          for (int i = 0; i < 1500; i++)
            {'id': i, 'avatarImgId_str': '$i', 'title': 'Long title $i'},
        ],
      },
    });
    final transport = NeteaseTransport(client: _Client(body));
    final result = await transport.request('/playlist/detail', {'id': '1'});
    expect(result['code'], 200);
    expect(
      (result['playlist']['tracks'] as List).last['avatarImgIdStr'],
      '1499',
    );
    final malformed = NeteaseTransport(client: _Client('[1, 2]'));
    await expectLater(
      malformed.request('/playlist/detail', {'id': '1'}),
      throwsA(isA<GatewayProtocolException>()),
    );
  });

  test(
    'normalizes nested gateway fields for small and large responses',
    () async {
      Map<String, dynamic> data(int count) => {
        'code': '200',
        'avatarImgId_str': 'root',
        'songs': [
          for (int i = 0; i < count; i++)
            {
              'id': i,
              'name': 'Song $i',
              'user': {'avatarImgId_str': '$i'},
              'artists': [
                {'avatarImgId_str': 'artist-$i'},
              ],
            },
        ],
      };
      for (final count in [2, 1500]) {
        final result = await decodeGatewayResponse(jsonEncode(data(count)));
        expect(result['code'], '200');
        expect(result['avatarImgIdStr'], 'root');
        final songs = result['songs'] as List;
        expect(songs, hasLength(count));
        expect(songs.last['user']['avatarImgIdStr'], '${count - 1}');
        expect(
          songs.last['artists'][0]['avatarImgIdStr'],
          'artist-${count - 1}',
        );
      }
    },
  );

  test(
    'rejects malformed JSON and non-object responses at both sizes',
    () async {
      for (final text in [
        '[]',
        '{oops',
        '[${List.filled(70000, ' ').join()}]',
        '{${List.filled(70000, ' ').join()}oops',
      ]) {
        await expectLater(
          () async => decodeGatewayResponse(text),
          throwsFormatException,
        );
      }
    },
  );
}
