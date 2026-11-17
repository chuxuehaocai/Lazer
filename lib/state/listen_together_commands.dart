/// Server sequences belong to the room; client sequences belong to a member.
/// A newcomer starting at sequence 1 must not be hidden by another member's 90.
class RoomCommandClock {
  static const _maximumMembers = 200;
  int _server = 0;
  final Map<String, int> _clients = {};
  (String, String, String, int?, String)? _unsequenced;

  bool accept(Map<String, dynamic> command) {
    final type = '${command['commandType'] ?? ''}'.toUpperCase();
    if (!const {'PLAY', 'PAUSE', 'GOTO', 'PROGRESS'}.contains(type)) {
      return false;
    }
    final server = (command['serverSeq'] as num?)?.toInt() ?? 0;
    if (server > 0) {
      if (server <= _server) return false;
      _server = server;
      return true;
    }
    final user = '${command['userId'] ?? ''}'.trim();
    final client = (command['clientSeq'] as num?)?.toInt() ?? 0;
    if (client > 0 && user.isNotEmpty) {
      if (client <= (_clients[user] ?? 0)) return false;
      _clients.remove(user);
      _clients[user] = client;
      if (_clients.length > _maximumMembers) {
        _clients.remove(_clients.keys.first);
      }
      return true;
    }
    final signature = (
      type,
      user,
      '${command['targetSongId'] ?? ''}'.trim(),
      (command['progress'] as num?)?.toInt(),
      '${command['playStatus'] ?? ''}',
    );
    if (signature == _unsequenced) return false;
    _unsequenced = signature;
    return true;
  }

  void clear() {
    _server = 0;
    _clients.clear();
    _unsequenced = null;
  }
}
