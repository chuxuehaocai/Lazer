import 'music_gateway.dart';

/// Holds independent live connections. Selecting one never reuses another
/// adapter's credentials, caches or in-flight requests.
class GatewayRegistry {
  final Map<String, MusicGateway> _connections = {};
  String? _active;

  static const providers = [MusicProvider.netease, MusicProvider.navidrome];

  static String keyOf(MusicGateway gateway) =>
      '${Uri.encodeComponent(gateway.provider.id)}:${Uri.encodeComponent(gateway.connectionId)}';

  List<MusicGateway> get connections => List.unmodifiable(_connections.values);
  MusicGateway? get active => _connections[_active];

  void add(MusicGateway gateway, {bool select = false}) {
    final key = keyOf(gateway);
    final existing = _connections[key];
    if (existing != null && !identical(existing, gateway)) {
      throw StateError(
        'A connection with this identity is already registered.',
      );
    }
    _connections[key] = gateway;
    if (select || _active == null) _active = key;
  }

  void select(String key) {
    if (!_connections.containsKey(key)) {
      throw ArgumentError('Unknown connection.');
    }
    _active = key;
  }

  MusicGateway resolve(MusicId id) {
    final key =
        '${Uri.encodeComponent(id.provider)}:${Uri.encodeComponent(id.connection)}';
    return _connections[key] ??
        (throw StateError('Music connection is unavailable.'));
  }

  void remove(String key, {bool close = true}) {
    final gateway = _connections.remove(key);
    if (_active == key) _active = _connections.keys.firstOrNull;
    if (close) gateway?.close();
  }

  void close() {
    final gateways = connections;
    _connections.clear();
    _active = null;
    for (final gateway in gateways) {
      gateway.close();
    }
  }
}
