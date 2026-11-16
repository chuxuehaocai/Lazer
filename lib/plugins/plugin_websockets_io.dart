import 'dart:async';
import 'dart:io';

import 'plugin_manifest.dart';
import 'plugin_socket_inbox.dart';

class PluginWebSockets {
  PluginWebSockets(
    this.manifest, {
    required this.clientGranted,
    required this.serverGranted,
    this.permissionRequester,
  });
  final PluginManifest manifest;
  bool clientGranted, serverGranted;
  final Future<bool> Function(String permission)? permissionRequester;
  final Map<String, _Socket> _clients = {};
  final Map<String, _Server> _servers = {};

  Future<Object?> client(Map<String, dynamic> spec) async {
    final operation = spec['operation'] as String? ?? 'open';
    final id = _id(spec);
    if (operation == 'open') {
      if (!clientGranted) {
        if (permissionRequester != null &&
            await permissionRequester!('websocket')) {
          clientGranted = true;
        } else {
          throw const FormatException('WebSocket permission required');
        }
      }
      final uri = Uri.parse(spec['url'] as String);
      if (!manifest.permitsWebSocket(uri)) {
        throw const FormatException('WebSocket permission denied');
      }
      if (!_clients.containsKey(id) && _clients.length >= 16) {
        throw const FormatException('Too many WebSocket connections');
      }
      await _clients.remove(id)?.close();
      _clients[id] = _Socket(
        await WebSocket.connect(
          uri.toString(),
        ).timeout(const Duration(seconds: 20)),
      );
      return true;
    }
    if (operation == 'close') {
      await _clients.remove(id)?.close();
      return true;
    }
    final socket = _clients[id];
    if (socket == null) throw const FormatException('WebSocket is not open');
    if (operation == 'send') {
      socket.send(pluginSocketData(spec['data']));
      return true;
    }
    if (operation == 'receive') {
      return socket.inbox.receive(pluginSocketTimeout(spec));
    }
    throw const FormatException('Unsupported WebSocket operation');
  }

  Future<Object?> server(Map<String, dynamic> spec) async {
    final operation = spec['operation'] as String? ?? 'listen';
    final id = _id(spec);
    if (operation == 'listen') {
      if (!serverGranted) {
        if (permissionRequester != null &&
            await permissionRequester!('websocketServer')) {
          serverGranted = true;
        } else {
          throw const FormatException('WebSocket server permission required');
        }
      }
      final host = spec['host'] as String? ?? '127.0.0.1';
      final port = (spec['port'] as num?)?.toInt() ?? 0;
      final path = spec['path'] as String?;
      if (!manifest.permitsWebSocketServer(host, port)) {
        throw const FormatException('WebSocket server permission denied');
      }
      if (!_servers.containsKey(id) && _servers.length >= 4) {
        throw const FormatException('Too many WebSocket servers');
      }
      await _servers.remove(id)?.close();
      final address = host == 'localhost'
          ? InternetAddress.loopbackIPv4
          : InternetAddress(host);
      final http = await HttpServer.bind(address, port, shared: false);
      final server = _Server(http, path);
      _servers[id] = server;
      return {'id': id, 'host': http.address.address, 'port': http.port};
    }
    if (operation == 'close') {
      await _servers.remove(id)?.close();
      return true;
    }
    final server = _servers[id];
    if (server == null) {
      throw const FormatException('WebSocket server is not listening');
    }
    if (operation == 'accept') {
      return server.accepted.receive(pluginSocketTimeout(spec));
    }
    if (operation == 'clients') {
      server.prune();
      return server.clients.keys.toList();
    }
    if (operation == 'broadcast') {
      final data = pluginSocketData(spec['data']);
      final connected = server.clients.values
          .where((client) => client.socket.readyState == WebSocket.open)
          .toList();
      for (final client in connected) {
        client.send(data);
      }
      return connected.length;
    }
    final clientId = spec['clientId'] as String?;
    if (operation == 'close_client') {
      await server.clients.remove(clientId)?.close();
      return true;
    }
    final client = server.clients[clientId];
    if (client == null) {
      throw const FormatException('WebSocket client is not connected');
    }
    if (operation == 'send') {
      client.send(pluginSocketData(spec['data']));
      return true;
    }
    if (operation == 'receive') {
      return client.inbox.receive(pluginSocketTimeout(spec));
    }
    throw const FormatException('Unsupported WebSocket server operation');
  }

  static String _id(Map<String, dynamic> spec) {
    final id = spec['id'] as String? ?? 'default';
    if (id.isEmpty || id.length > 100) {
      throw const FormatException('Invalid WebSocket id');
    }
    return id;
  }

  Future<void> close() async {
    final closing = [
      for (final socket in _clients.values) socket.close(),
      for (final server in _servers.values) server.close(),
    ];
    _clients.clear();
    _servers.clear();
    await Future.wait(closing);
  }
}

class _Socket {
  _Socket(this.socket, {void Function()? onDone}) {
    socket.pingInterval = const Duration(seconds: 30);
    subscription = socket.listen(
      (data) {
        if (!inbox.add(data as Object)) {
          socket.close(WebSocketStatus.messageTooBig);
          inbox.close(discard: true);
        }
      },
      onError: (Object error) {
        inbox.close();
        onDone?.call();
      },
      onDone: () {
        inbox.close();
        onDone?.call();
      },
    );
  }
  final WebSocket socket;
  final PluginSocketInbox inbox = PluginSocketInbox();
  late final StreamSubscription<dynamic> subscription;
  void send(Object data) {
    if (socket.readyState != WebSocket.open) {
      throw const FormatException('WebSocket is closed');
    }
    socket.add(data);
  }

  Future<void> close() async {
    inbox.close(discard: true);
    await subscription.cancel();
    await socket.close().timeout(const Duration(seconds: 1), onTimeout: () {});
  }
}

class _Server {
  _Server(this.http, this.path) {
    subscription = http.listen(
      _upgrade,
      onError: (Object error) {
        close();
      },
    );
  }
  final HttpServer http;
  final String? path;
  final Map<String, _Socket> clients = {};
  final PluginSocketInbox accepted = PluginSocketInbox();
  late final StreamSubscription<HttpRequest> subscription;
  int _next = 0, _upgrading = 0;
  bool _closed = false;

  void prune() {
    clients.removeWhere((_, client) {
      if (!client.inbox.drained) return false;
      client.close();
      return true;
    });
  }

  Future<void> _upgrade(HttpRequest request) async {
    prune();
    if (_closed ||
        clients.length + _upgrading >= 32 ||
        (path != null && request.uri.path != path) ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    _upgrading++;
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      if (_closed) {
        await socket.close();
        return;
      }
      final id = '${++_next}';
      clients[id] = _Socket(socket);
      // Retain a closed client's bounded inbox until Lua has drained/closed it;
      // this avoids losing the final message before the next receive call.
      if (!accepted.add({
        'clientId': id,
        'address': request.connectionInfo?.remoteAddress.address,
      })) {
        clients.remove(id)?.close();
      }
    } catch (_) {
      /* Failed handshakes do not stop the listener. */
    } finally {
      _upgrading--;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    accepted.close(discard: true);
    final closing = [for (final client in clients.values) client.close()];
    clients.clear();
    await http.close(force: true);
    await subscription.cancel();
    await Future.wait(closing);
  }
}
