import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plugin_manifest.dart';
import 'plugin_socket_inbox.dart';

class PluginSockets {
  PluginSockets(
    this.manifest, {
    required this.clientGranted,
    required this.serverGranted,
    this.permissionRequester,
  });

  final PluginManifest manifest;
  bool clientGranted, serverGranted;
  final Future<bool> Function(String permission)? permissionRequester;

  final Map<String, _TcpSocket> _clients = {};
  final Map<String, _TcpServer> _servers = {};

  Future<Object?> client(Map<String, dynamic> spec) async {
    final operation = spec['operation'] as String? ?? 'connect';
    final id = _id(spec);
    if (operation == 'connect' || operation == 'open') {
      final host = spec['host'] as String? ?? '127.0.0.1';
      final port = (spec['port'] as num?)?.toInt() ?? 0;
      if (!manifest.permitsSocket(host, port)) {
        throw const FormatException('Socket permission denied');
      }
      if (!clientGranted) {
        if (permissionRequester != null &&
            await permissionRequester!('socket')) {
          clientGranted = true;
        } else {
          throw const FormatException('Socket permission required');
        }
      }
      if (!_clients.containsKey(id) && _clients.length >= 16) {
        throw const FormatException('Too many Socket connections');
      }
      await _clients.remove(id)?.close();
      final timeout = Duration(milliseconds: pluginSocketTimeout(spec));
      final socket = await Socket.connect(host, port, timeout: timeout);
      _clients[id] = _TcpSocket(socket);
      return {'id': id, 'host': host, 'port': port};
    }
    if (operation == 'close') {
      await _clients.remove(id)?.close();
      return true;
    }
    final client = _clients[id];
    if (client == null) throw const FormatException('Socket is not open');
    if (operation == 'send') {
      client.send(pluginSocketData(spec['data']));
      await client.flush();
      return true;
    }
    if (operation == 'receive') {
      final data = await client.inbox.receive(pluginSocketTimeout(spec));
      return _formatReceived(data, spec['format'] as String?);
    }
    throw const FormatException('Unsupported Socket operation');
  }

  Future<Object?> server(Map<String, dynamic> spec) async {
    final operation = spec['operation'] as String? ?? 'listen';
    final id = _id(spec);
    if (operation == 'listen' || operation == 'bind') {
      final host = spec['host'] as String? ?? '127.0.0.1';
      final port = (spec['port'] as num?)?.toInt() ?? 0;
      if (!manifest.permitsSocketServer(host, port)) {
        throw const FormatException('Socket server permission denied');
      }
      if (!serverGranted) {
        if (permissionRequester != null &&
            await permissionRequester!('socketServer')) {
          serverGranted = true;
        } else {
          throw const FormatException('Socket server permission required');
        }
      }
      if (!_servers.containsKey(id) && _servers.length >= 4) {
        throw const FormatException('Too many Socket servers');
      }
      await _servers.remove(id)?.close();
      final address = host == 'localhost'
          ? InternetAddress.loopbackIPv4
          : InternetAddress(host);
      final server = await ServerSocket.bind(address, port, shared: false);
      _servers[id] = _TcpServer(server);
      return {'id': id, 'host': server.address.address, 'port': server.port};
    }
    if (operation == 'close') {
      await _servers.remove(id)?.close();
      return true;
    }
    final server = _servers[id];
    if (server == null) {
      throw const FormatException('Socket server is not listening');
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
      int count = 0;
      for (final client in server.clients.values) {
        try {
          client.send(data);
          count++;
        } catch (_) {}
      }
      return count;
    }
    final clientId = spec['clientId'] as String?;
    if (clientId == null || !server.clients.containsKey(clientId)) {
      throw const FormatException('Socket client is not connected');
    }
    final client = server.clients[clientId]!;
    if (operation == 'send') {
      client.send(pluginSocketData(spec['data']));
      await client.flush();
      return true;
    }
    if (operation == 'receive') {
      final data = await client.inbox.receive(pluginSocketTimeout(spec));
      return _formatReceived(data, spec['format'] as String?);
    }
    if (operation == 'close_client') {
      await server.clients.remove(clientId)?.close();
      return true;
    }
    throw const FormatException('Unsupported Socket server operation');
  }

  Object? _formatReceived(Object? data, String? format) {
    if (data == null) return null;
    if (format == 'binary') {
      if (data is List<int>) return data;
      if (data is String) return utf8.encode(data);
    }
    if (format == 'text') {
      if (data is String) return data;
      if (data is List<int>) return utf8.decode(data, allowMalformed: true);
    }
    if (data is String) return data;
    if (data is List<int>) {
      try {
        return utf8.decode(data);
      } catch (_) {
        return data;
      }
    }
    return data;
  }

  String _id(Map<String, dynamic> spec) {
    final id = spec['id'] as String? ?? 'default';
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(id)) {
      throw const FormatException('Invalid Socket id');
    }
    return id;
  }

  Future<void> close() async {
    await Future.wait([
      for (final socket in _clients.values) socket.close(),
      for (final server in _servers.values) server.close(),
    ]);
    _clients.clear();
    _servers.clear();
  }
}

class _TcpSocket {
  _TcpSocket(this.socket, {void Function()? onDone}) {
    subscription = socket.listen(
      (data) {
        if (!inbox.add(data)) {
          socket.destroy();
        }
      },
      onError: (_) => inbox.close(),
      onDone: () {
        inbox.close();
        onDone?.call();
      },
      cancelOnError: true,
    );
  }

  final Socket socket;
  late final StreamSubscription<List<int>> subscription;
  final PluginSocketInbox inbox = PluginSocketInbox();

  void send(Object data) {
    if (data is String) {
      socket.add(utf8.encode(data));
    } else if (data is List<int>) {
      socket.add(data);
    }
  }

  Future<void> flush() async {
    try {
      await socket.flush();
    } catch (_) {}
  }

  Future<void> close() async {
    inbox.close(discard: true);
    await subscription.cancel();
    socket.destroy();
  }
}

class _TcpServer {
  _TcpServer(this.server) {
    subscription = server.listen((socket) {
      if (clients.length >= 32) {
        socket.destroy();
        return;
      }
      final clientId =
          '${DateTime.now().microsecondsSinceEpoch}_${clients.length}';
      final client = _TcpSocket(
        socket,
        onDone: () {
          if (clients[clientId]?.inbox.drained ?? true) {
            clients.remove(clientId);
          }
        },
      );
      clients[clientId] = client;
      if (!accepted.add({
        'clientId': clientId,
        'remoteAddress': socket.remoteAddress.address,
        'remotePort': socket.remotePort,
      })) {
        clients.remove(clientId)?.close();
      }
    });
  }

  final ServerSocket server;
  late final StreamSubscription<Socket> subscription;
  final Map<String, _TcpSocket> clients = {};
  final PluginSocketInbox accepted = PluginSocketInbox();

  void prune() {
    clients.removeWhere((_, client) => client.inbox.drained);
  }

  Future<void> close() async {
    accepted.close(discard: true);
    await subscription.cancel();
    for (final client in clients.values) {
      await client.close();
    }
    clients.clear();
    await server.close();
  }
}
