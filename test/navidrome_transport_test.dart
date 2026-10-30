import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/navidrome_transport.dart';

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
  @override
  void close() => closed = true;
}

void main() {
  test(
    'real HTTP carries form credentials and repeated playlist parameters',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <(String, Map<String, List<String>>)>[];
      final gateway = NavidromeGateway(
        serverUrl: 'http://127.0.0.1:${server.port}/proxy',
        username: 'alice',
        allowInsecureHttp: true,
      );
      final mediaClient = http.Client();
      addTearDown(() async {
        gateway.close();
        mediaClient.close();
        await server.close(force: true);
      });
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        final parameters = request.method == 'POST'
            ? Uri(query: body).queryParametersAll
            : request.uri.queryParametersAll;
        requests.add((request.uri.path, parameters));
        if (request.method == 'POST') {
          expect(request.uri.hasQuery, isFalse);
          expect(
            request.headers.contentType!.mimeType,
            'application/x-www-form-urlencoded',
          );
        }
        if (request.uri.path.endsWith('/stream.view')) {
          request.response.headers.contentType = ContentType('audio', 'flac');
          request.response.add([102, 76, 97, 67]);
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'subsonic-response': {
                'status': 'ok',
                if (request.uri.path.endsWith('/getSong.view'))
                  'song': {
                    'id': 'uuid / + &',
                    'title': 'Song',
                    'duration': 60,
                    'suffix': 'flac',
                    'contentType': 'audio/flac',
                  },
              },
            }),
          );
        }
        await request.response.close();
      });
      await gateway.login('password & +');
      final song = gateway.id(MusicEntityKind.song, 'uuid / + &');
      final playlist = gateway.id(MusicEntityKind.playlist, 'playlist / +');
      await gateway.addToPlaylist(playlist, [song, song]);
      expect(requests.last.$1, '/proxy/rest/updatePlaylist.view');
      expect(requests.last.$2['songIdToAdd'], ['uuid / + &', 'uuid / + &']);
      expect(requests.last.$2['playlistId'], ['playlist / +']);
      final source = await gateway.stream(song);
      final response = await mediaClient.get(source.uri);
      expect(response.bodyBytes, [102, 76, 97, 67]);
      expect(requests.last.$1, '/proxy/rest/stream.view');
      expect(requests.last.$2['t']!.single, gateway.session!.token);
      expect(requests.last.$2['format'], ['raw']);
    },
  );

  test(
    'transport rejects redirected credentials and cancels the body',
    () async {
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final client = _Client((request) async {
        expect((request as http.Request).followRedirects, isFalse);
        return http.StreamedResponse(
          body.stream,
          302,
          headers: {'location': 'https://other.example'},
        );
      });
      final server = Uri.parse('https://music.example/');
      final transport = NavidromeTransport(server: server, client: client);
      addTearDown(transport.close);
      final session = NavidromeSession.fromPassword(
        server: server,
        username: 'alice',
        password: 'secret',
      );
      await expectLater(
        transport.request('ping', session),
        throwsA(
          isA<MusicGatewayException>().having(
            (error) => error.httpStatus,
            'redirect rejected',
            302,
          ),
        ),
      );
      expect(cancelled, isTrue);
    },
  );

  test(
    'oversized responses are rejected before buffering their body',
    () async {
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final client = _Client(
        (_) async => http.StreamedResponse(
          body.stream,
          200,
          contentLength: 16 * 1024 * 1024 + 1,
        ),
      );
      final server = Uri.parse('https://music.example/');
      final transport = NavidromeTransport(server: server, client: client);
      addTearDown(transport.close);
      final session = NavidromeSession.fromPassword(
        server: server,
        username: 'alice',
        password: 'secret',
      );
      await expectLater(
        transport.request('ping', session),
        throwsA(
          isA<MusicGatewayException>().having(
            (error) => error.reason,
            'bounded response',
            'Response too large',
          ),
        ),
      );
      expect(cancelled, isTrue);
    },
  );

  test(
    'timeouts and network errors do not retain client exception text',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final client = _Client((_) => pending.future);
      final server = Uri.parse('https://music.example/');
      final transport = NavidromeTransport(
        server: server,
        client: client,
        timeout: const Duration(milliseconds: 30),
      );
      addTearDown(transport.close);
      final session = NavidromeSession.fromPassword(
        server: server,
        username: 'alice',
        password: 'secret',
      );
      await expectLater(
        transport.request('ping', session),
        throwsA(
          isA<MusicGatewayException>().having(
            (error) => error.reason,
            'timeout',
            'Request timed out',
          ),
        ),
      );
      pending.completeError(http.ClientException('sensitive-server-details'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'transport prevents endpoint and authentication parameter overrides',
    () async {
      final client = _Client((_) async => throw StateError('must not send'));
      final server = Uri.parse('https://music.example/');
      final transport = NavidromeTransport(server: server, client: client);
      final session = NavidromeSession.fromPassword(
        server: server,
        username: 'alice',
        password: 'secret',
      );
      for (final parameter in ['u', 't', 's', 'p', 'f', 'v', 'c']) {
        await expectLater(
          transport.request('ping', session, {parameter: 'override'}),
          throwsArgumentError,
        );
      }
      await expectLater(
        transport.request('../ping', session),
        throwsArgumentError,
      );
      expect(
        () => transport.mediaUri('ping', session, {}),
        throwsArgumentError,
      );
      transport.close();
      expect(client.closed, isTrue);
      await expectLater(transport.request('ping', session), throwsStateError);
    },
  );
}
