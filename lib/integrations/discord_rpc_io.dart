import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../state/app_state.dart';

/// Small Discord IPC client. It only connects when the user enables RPC and
/// supplies an application client ID; no network socket is opened otherwise.
class DiscordRpcController {
  DiscordRpcController(this.state) {
    state.addListener(_changed);
    _changed();
  }

  final AppState state;
  Socket? _socket;
  Future<void> _tail = Future<void>.value();
  Timer? _clock;
  bool _closed = false;
  String? _lastTrack;
  bool? _lastPlaying;

  Future<void> get settled => _tail;

  void _changed() {
    if (_closed) return;
    final enabled =
        state.discordRpcEnabled &&
        state.discordClientId.trim().isNotEmpty &&
        !state.independentPlayback;
    if (!enabled) {
      _clock?.cancel();
      _clock = null;
      _enqueue(_disconnect);
      return;
    }
    _enqueue(_publish);
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _enqueue(_publish);
    });
  }

  void _enqueue(Future<void> Function() task) {
    _tail = _tail.then((_) => task()).catchError((_) {
      _socket = null;
    });
  }

  Future<void> _connect() async {
    if (_socket != null) return;
    for (var i = 0; i < 10; i++) {
      try {
        final path = Platform.isWindows
            ? r'\\?\pipe\discord-ipc-$i'
            : '/tmp/discord-ipc-$i';
        final socket = Platform.isWindows
            ? await Socket.connect(path, 0, timeout: const Duration(seconds: 1))
            : await Socket.connect(
                InternetAddress(path, type: InternetAddressType.unix),
                0,
                timeout: const Duration(seconds: 1),
              );
        _socket = socket;
        await _send(0, {'v': 1, 'client_id': state.discordClientId.trim()});
        return;
      } catch (_) {}
    }
  }

  Future<void> _publish() async {
    if (_closed || !state.discordRpcEnabled || state.current == null) return;
    await _connect();
    if (_socket == null) return;
    final track = state.current!;
    final playing = state.playing;
    final key = '${track.id}:${playing ? 1 : 0}';
    if (key == _lastTrack && _lastPlaying == playing && !playing) return;
    _lastTrack = key;
    _lastPlaying = playing;
    final position = state.precisePosition;
    final duration = track.duration;
    final args = <String, dynamic>{
      'details': track.title,
      'state': track.artist,
      'type': 2,
      'instance': false,
      'assets': <String, dynamic>{'large_text': track.album},
    };
    if (playing && duration > Duration.zero) {
      final now = DateTime.now().millisecondsSinceEpoch;
      args['timestamps'] = <String, dynamic>{
        'start': now - position.inMilliseconds,
        'end': now + (duration - position).inMilliseconds,
      };
    }
    await _send(1, {
      'cmd': 'SET_ACTIVITY',
      'args': {'pid': pid, 'activity': args},
      'nonce': '${DateTime.now().microsecondsSinceEpoch}',
    });
  }

  Future<void> _send(int opcode, Map<String, dynamic> payload) async {
    final socket = _socket;
    if (socket == null) return;
    final bytes = utf8.encode(jsonEncode(payload));
    final packet = BytesBuilder()
      ..add(_u32(opcode))
      ..add(_u32(bytes.length))
      ..add(bytes);
    socket.add(packet.takeBytes());
    await socket.flush();
  }

  List<int> _u32(int value) => <int>[
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];

  Future<void> _disconnect() async {
    final socket = _socket;
    _socket = null;
    _lastTrack = null;
    _lastPlaying = null;
    await socket?.close();
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    state.removeListener(_changed);
    _clock?.cancel();
    _enqueue(_disconnect);
  }
}
