import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'build_safe_notifier.dart';

/// A participant in a listen-together room.
class ListenTogetherMember {
  const ListenTogetherMember({
    required this.userId,
    required this.name,
    this.avatarUrl,
  });

  final int userId;
  final String name;
  final String? avatarUrl;
}

/// The account's listen-together room.
///
/// NetEase models this as a server-side room with a room id and an inviter id;
/// the client keeps it alive with a heartbeat that carries the current song,
/// play status and progress. Creating a room and joining by invite are enough
/// for the shared session; the playback itself stays on this device.
class ListenTogetherController extends ChangeNotifier with BuildSafeNotifier {
  ListenTogetherController({required this.state}) {
    state.addListener(_onPlaybackState);
    state.ticks.addListener(_onPlaybackTick);
  }

  final AppState state;

  bool loading = false;
  bool active = false;
  String? roomId;
  int? inviterId;
  String? error;
  List<ListenTogetherMember> members = const <ListenTogetherMember>[];
  Timer? _heartbeat;
  bool _disposed = false;

  // Play-command bookkeeping. The values mirror the APK's PlayCommand:
  // commandType is PLAY / PAUSE / PROGRESS, progress is in milliseconds and
  // triggerType is MANUAL for local input or AUTO for a track hand-off.
  int _clientSeq = 0;
  int? _lastSongId;
  bool? _lastPlaying;
  int _lastPositionMs = 0;
  DateTime _lastProgressCommand = DateTime.fromMillisecondsSinceEpoch(0);

  bool get ready => active && (roomId?.isNotEmpty ?? false);

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    state.removeListener(_onPlaybackState);
    state.ticks.removeListener(_onPlaybackTick);
    super.dispose();
  }

  Future<bool> create() async {
    if (state.isNavidrome) {
      error = '当前音乐平台不支持一起听。';
      _notify();
      return false;
    }
    if (!state.signedIn) {
      error = '请先登录后再一起听'; // i18n:key
      _notify();
      return false;
    }
    loading = true;
    error = null;
    _notify();
    try {
      final Map<String, dynamic> body = await state.catalog
          .listenTogetherCreateRoom();
      final Map<String, dynamic> data = _dataOf(body);
      final String id = '${data['roomId'] ?? data['roomid'] ?? ''}'.trim();
      if (id.isEmpty) {
        error = '创建一起听房间失败，请稍后重试。'; // i18n:key
        return false;
      }
      roomId = id;
      inviterId =
          int.tryParse('${data['inviterId'] ?? data['userId'] ?? ''}') ??
          state.user.userId;
      active = true;
      members = _membersOf(body);
      _startHeartbeat();
      _primePlayback();
      _sendPlayCommand(state.playing ? 'PLAY' : 'PAUSE');
      return true;
    } catch (_) {
      error = '创建一起听房间失败，请稍后重试。'; // i18n:key
      return false;
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<bool> join(String rawCode) async {
    final (String? room, int? inviter) = parseInvite(rawCode);
    if (room == null || inviter == null || inviter <= 0) {
      error = '邀请码无效。'; // i18n:key
      _notify();
      return false;
    }
    if (!state.signedIn) {
      error = '请先登录后再一起听'; // i18n:key
      _notify();
      return false;
    }
    loading = true;
    error = null;
    _notify();
    try {
      final Map<String, dynamic> body = await state.catalog
          .listenTogetherAccept(room, inviter);
      final int code = (body['code'] as num?)?.toInt() ?? 200;
      if (code != 200) {
        error = '加入一起听失败，请检查邀请码。'; // i18n:key
        return false;
      }
      roomId = room;
      inviterId = inviter;
      active = true;
      members = _membersOf(body);
      await refresh();
      _startHeartbeat();
      // Joining follows the room; the current position is only the baseline
      // against which the next local pause/seek/track change is compared.
      _primePlayback();
      return true;
    } catch (_) {
      error = '加入一起听失败，请检查邀请码。'; // i18n:key
      return false;
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> refresh() async {
    final String? id = roomId;
    if (id == null || id.isEmpty) return;
    try {
      final Map<String, dynamic> body = await state.catalog
          .listenTogetherRoomCheck(id);
      final List<ListenTogetherMember> found = _membersOf(body);
      if (found.isNotEmpty) members = found;
      _notify();
    } catch (_) {
      // A failed status poll must not tear the room down; the heartbeat will
      // retry on the next tick.
    }
  }

  Future<void> leave() async {
    final String? id = roomId;
    _heartbeat?.cancel();
    _heartbeat = null;
    active = false;
    roomId = null;
    inviterId = null;
    members = const <ListenTogetherMember>[];
    error = null;
    _lastSongId = null;
    _lastPlaying = null;
    _lastPositionMs = 0;
    _notify();
    if (id != null && id.isNotEmpty && state.signedIn) {
      try {
        await state.catalog.listenTogetherEnd(id);
      } catch (_) {
        // Leaving locally is what matters; the server expires an idle room.
      }
    }
  }

  /// Accepts the forms the APK's invite share produces: a link with
  /// `roomId`/`inviterId` query parameters, `roomId|inviterId`, or two
  /// whitespace-separated values.
  static (String?, int?) parseInvite(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return (null, null);
    final Uri? uri = Uri.tryParse(text);
    if (uri != null && uri.queryParameters.isNotEmpty) {
      final String? room =
          uri.queryParameters['roomId'] ?? uri.queryParameters['roomid'];
      final String? inviter =
          uri.queryParameters['inviterId'] ?? uri.queryParameters['inviterid'];
      if (room != null && inviter != null) {
        return (room, int.tryParse(inviter));
      }
    }
    final List<String> parts = text.split(RegExp(r'[|,\s]+'));
    if (parts.length >= 2) {
      return (parts.first.trim(), int.tryParse(parts[1].trim()));
    }
    return (null, null);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) => _beat());
    _beat();
  }

  void _primePlayback() {
    _lastSongId = int.tryParse(state.current?.id ?? '');
    _lastPlaying = state.playing;
    _lastPositionMs = state.position.inMilliseconds;
  }

  /// Sends PLAY / PAUSE / PROGRESS as the local transport changes.
  ///
  /// The APK's PlayCommand uses uppercase PLAY / PAUSE / PROGRESS (plus
  /// NEXT / PREVIOUS / GOTO), a millisecond progress and a MANUAL/AUTO trigger.
  /// A track hand-off is sent as PLAY with the new target so the room never
  /// has to guess which queue entry came next.
  void _onPlaybackState() {
    if (!ready) return;
    final int? songId = int.tryParse(state.current?.id ?? '');
    if (songId == null || songId <= 0) return;
    final bool playing = state.playing;
    if (_lastSongId != songId) {
      final int former = _lastSongId ?? songId;
      _lastSongId = songId;
      _lastPlaying = playing;
      _lastPositionMs = state.position.inMilliseconds;
      _sendPlayCommand('PLAY', formerSongId: former, trigger: 'AUTO');
      return;
    }
    if (_lastPlaying == null) {
      _lastPlaying = playing;
      _lastPositionMs = state.position.inMilliseconds;
      return;
    }
    if (_lastPlaying != playing) {
      _lastPlaying = playing;
      _lastPositionMs = state.position.inMilliseconds;
      _sendPlayCommand(playing ? 'PLAY' : 'PAUSE');
    }
  }

  /// Detects a seek by a jump in the 100 ms tick lane and reports PROGRESS.
  void _onPlaybackTick() {
    if (!ready) return;
    final int? songId = int.tryParse(state.current?.id ?? '');
    if (songId == null || songId != _lastSongId) {
      _lastSongId = songId;
      _lastPositionMs = state.position.inMilliseconds;
      return;
    }
    final int position = state.position.inMilliseconds;
    final int delta = position - _lastPositionMs;
    _lastPositionMs = position;
    if (delta.abs() < 1500) return;
    final DateTime now = DateTime.now();
    if (now.difference(_lastProgressCommand) <
        const Duration(milliseconds: 500)) {
      return;
    }
    _lastProgressCommand = now;
    _sendPlayCommand('PROGRESS', progressMs: position, trigger: 'MANUAL');
  }

  void _sendPlayCommand(
    String type, {
    int? formerSongId,
    int? progressMs,
    String trigger = 'MANUAL',
  }) {
    final String? id = roomId;
    final int songId = int.tryParse(state.current?.id ?? '') ?? 0;
    if (!ready || id == null || songId <= 0 || !state.signedIn) return;
    final int position = (progressMs ?? state.position.inMilliseconds).clamp(
      0,
      1 << 62,
    );
    final int userId = state.user.userId;
    final Map<String, Object?> command = <String, Object?>{
      'clientSeq': ++_clientSeq,
      'commandType': type,
      'formerSongId': '${formerSongId ?? songId}',
      'ignoreUserId': <int>[userId],
      'playStatus': state.playing ? 'PLAY' : 'PAUSE',
      'progress': position,
      'serverSeq': 0,
      'targetSongId': '$songId',
      'triggerType': trigger,
      'userId': userId,
    };
    unawaited(
      state.catalog
          .listenTogetherPlayCommand(id, command)
          .catchError((Object _) => <String, dynamic>{}),
    );
  }

  void _beat() {
    final String? id = roomId;
    if (!active || id == null || id.isEmpty || _disposed) return;
    final int songId = int.tryParse(state.current?.id ?? '') ?? 0;
    unawaited(
      state.catalog
          .listenTogetherHeartbeat(
            id,
            songId,
            state.playing ? 'PLAY' : 'PAUSE',
            state.position.inMilliseconds,
          )
          .catchError((_) => <String, dynamic>{}),
    );
  }

  static Map<String, dynamic> _dataOf(Map<String, dynamic> body) {
    final dynamic data = body['data'];
    return data is Map<String, dynamic> ? data : body;
  }

  static List<ListenTogetherMember> _membersOf(Map<String, dynamic> body) {
    final Map<String, dynamic> data = _dataOf(body);
    final dynamic list =
        data['members'] ?? data['users'] ?? data['participants'];
    if (list is! List) return const <ListenTogetherMember>[];
    final List<ListenTogetherMember> members = <ListenTogetherMember>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final dynamic rawId = item['userId'] ?? item['uid'];
      if (rawId is! num) continue;
      members.add(
        ListenTogetherMember(
          userId: rawId.toInt(),
          name: '${item['nickname'] ?? item['name'] ?? item['userName'] ?? ''}',
          avatarUrl: item['avatarUrl'] as String? ?? item['avatar'] as String?,
        ),
      );
    }
    return members;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
