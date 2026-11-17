import '../gateway/music_gateway.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/models.dart' show Track;
import 'app_state.dart';
import 'build_safe_notifier.dart';

/// A participant in a listen-together room.
class ListenTogetherMember {
  const ListenTogetherMember({
    required this.userId,
    required this.name,
    this.avatarUrl,
  });

  final String userId;
  final String name;
  final String? avatarUrl;
}

/// The account's listen-together room.
///
/// A provider models this as a server-side room with a room id and an inviter
/// id. The client owns three things the room cannot work without:
///
///  * the **heartbeat** — the room's clock. Every beat refreshes this member's
///    presence, republishes the queue version and brings back the room's own
///    state, so one request covers presence, roster and track changes.
///  * the **queue version** — the room only sends "changed", not the list. A
///    version that no longer matches what this client last published pulls the
///    room queue, and a local queue change republishes it.
///  * the **play command lane** — another member's play/pause/seek/track change
///    arrives as a sequence-numbered command; applying it locally without
///    echoing it back is what makes two listeners hear the same thing.
class ListenTogetherController extends ChangeNotifier with BuildSafeNotifier {
  ListenTogetherController({required this.state}) {
    state.addListener(_onPlaybackState);
    state.ticks.addListener(_onPlaybackTick);
  }

  final AppState state;
  MusicGateway? _roomOwner;
  MusicGateway get _selectedOwner {
    final song = MusicId.tryParse(state.current?.id ?? '');
    if (song != null) {
      try {
        return state.catalog.connections.resolve(song);
      } catch (_) {}
    }
    return state.catalog.activeGateway;
  }

  MusicGateway get _owner => _roomOwner ?? _selectedOwner;

  bool loading = false;
  bool active = false;
  String? roomId;
  String? inviterId;
  String? error;
  List<ListenTogetherMember> members = const <ListenTogetherMember>[];

  /// The room queue as the service reports it. Empty until the first pull;
  /// [queueInSync] tells the room sheet whether it still matches this client.
  List<Track> roomQueue = const <Track>[];
  bool queueInSync = true;

  Timer? _heartbeat;
  bool _disposed = false;
  bool _beating = false;

  // Shared transport changes; Lua constructs any service-specific envelope.
  // commandType is PLAY / PAUSE / PROGRESS, progress is in milliseconds and
  // triggerType is MANUAL for local input or AUTO for a track hand-off.
  int _clientSeq = 0;
  String? _lastSongId;
  bool? _lastPlaying;
  int _lastPositionMs = 0;
  DateTime _lastProgressCommand = DateTime.fromMillisecondsSinceEpoch(0);

  // The room protocol.
  static const Duration _beatInterval = Duration(seconds: 5);

  /// Serialized queue version last published and last seen from the service.
  String _playlistVersion = '[]';
  String _roomVersion = '';
  String _publishedVersion = '';

  /// Highest remote command sequence already applied, so a command the service
  /// keeps returning is not replayed on every beat.
  int _appliedSeq = 0;

  /// True while a remote command is writing local playback, so the resulting
  /// state change is not reported back as a local one.
  bool _applyingRemote = false;

  DateTime _lastQueuePush = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether the last room answer actually changed something the sheet shows.
  bool _changedByLastRoom = false;

  String? get _currentSongId {
    final id = MusicId.tryParse(state.current?.id ?? '');
    final owner = _owner;
    return id != null &&
            id.provider == owner.provider.id &&
            id.connection == owner.connectionId
        ? id.value
        : null;
  }

  String? get _ownUserId => _owner.user?.id.value;

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
    if (!_selectedOwner.supports(MusicCapability.listenTogether)) {
      error = '当前音乐平台不支持一起听。'; // i18n:key
      _notify();
      return false;
    }
    if (_selectedOwner.user == null) {
      error = '请先登录后再一起听'; // i18n:key
      _notify();
      return false;
    }
    loading = true;
    error = null;
    _notify();
    try {
      // Creating from the playing track is what the share sheet does: the room
      // opens with a song to listen to instead of an empty queue that both
      // sides would have to fill.
      final String? songId = _currentSongId;
      final Map<String, dynamic> body = await _selectedOwner.listenTogether(
        songId == null || songId.isEmpty ? 'create' : 'createMulti',
        songId == null || songId.isEmpty
            ? const <String, dynamic>{}
            : <String, dynamic>{
                'songId': songId,
                'playedTime': state.position.inMilliseconds,
                'nextSongIds': _upcomingIds(),
              },
      );
      final Map<String, dynamic> data = _dataOf(body);
      // A plugin that predates the room protocol answers with a bare room
      // object, so a missing `code` still means success; only an explicit
      // failure code or a missing room id rejects the room.
      final int code = (body['code'] as num?)?.toInt() ?? 200;
      final String id = '${data['roomId'] ?? body['roomId'] ?? ''}'.trim();
      if (code != 200 || id.isEmpty) {
        error = '创建一起听房间失败，请稍后重试。'; // i18n:key
        return false;
      }
      _roomOwner = _selectedOwner;
      roomId = id;
      inviterId =
          '${data['inviterId'] ?? body['inviterId'] ?? _selectedOwner.user?.id.value ?? ''}';
      active = true;
      members = _membersOf(body);
      _primePlayback();
      _publishQueue(force: true);
      _startHeartbeat();
      _sendPlayCommand(state.playing ? 'PLAY' : 'PAUSE');
      return true;
    } on MusicGatewayException catch (failure) {
      error = failure.authenticationFailure
          ? '请先登录后再一起听' // i18n:key
          : '创建一起听房间失败，请稍后重试。'; // i18n:key
      return false;
    } catch (_) {
      error = '创建一起听房间失败，请稍后重试。'; // i18n:key
      return false;
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<bool> join(String rawCode) async {
    final (String? room, String? inviter) = parseInvite(rawCode);
    if (room == null || inviter == null || inviter.isEmpty) {
      error = '邀请码无效。'; // i18n:key
      _notify();
      return false;
    }
    if (_selectedOwner.user == null) {
      error = '请先登录后再一起听'; // i18n:key
      _notify();
      return false;
    }
    loading = true;
    error = null;
    _notify();
    try {
      final Map<String, dynamic> body = await _selectedOwner.listenTogether(
        'join',
        {'roomId': room, 'inviterId': inviter},
      );
      final int code = (body['code'] as num?)?.toInt() ?? 200;
      if (code != 200) {
        error = '加入一起听失败，请检查邀请码。'; // i18n:key
        return false;
      }
      _roomOwner = _selectedOwner;
      roomId = room;
      inviterId = inviter;
      active = true;
      members = _membersOf(body);
      await refresh();
      _primePlayback();
      _startHeartbeat();
      // The room already has a song and a queue; the join is a sync, not a
      // fresh start, so the current position is only the baseline against which
      // the next local pause/seek/track change is compared.
      _syncFromRoom();
      return true;
    } on MusicGatewayException catch (failure) {
      error = failure.authenticationFailure
          ? '请先登录后再一起听' // i18n:key
          : '加入一起听失败，请检查邀请码。'; // i18n:key
      return false;
    } catch (_) {
      error = '加入一起听失败，请检查邀请码。'; // i18n:key
      return false;
    } finally {
      loading = false;
      _notify();
    }
  }

  /// Re-reads the room: roster, playing track and queue.
  ///
  /// The room sheet calls this when it opens and the heartbeat calls it with
  /// the answer it already has, so a manual refresh and a beat share one path.
  Future<void> refresh() async {
    final String? id = roomId;
    if (id == null || id.isEmpty) return;
    try {
      final Map<String, dynamic> body = await _owner.listenTogether('status', {
        'roomId': id,
      });
      _applyRoom(body);
      _notify();
    } catch (_) {
      // A failed status poll must not tear the room down; the heartbeat will
      // retry on the next tick.
    }
  }

  Future<void> leave() async {
    final String? id = roomId;
    final owner = _owner;
    _roomOwner = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    active = false;
    roomId = null;
    inviterId = null;
    members = const <ListenTogetherMember>[];
    roomQueue = const <Track>[];
    queueInSync = true;
    error = null;
    _lastSongId = null;
    _lastPlaying = null;
    _lastPositionMs = 0;
    _playlistVersion = '[]';
    _publishedVersion = '';
    _roomVersion = '';
    _appliedSeq = 0;
    _notify();
    if (id != null && id.isNotEmpty && owner.user != null) {
      try {
        await owner.listenTogether('leave', {'roomId': id});
      } catch (_) {
        // Leaving locally is what matters; the server expires an idle room.
      }
    }
  }

  /// Replaces the local queue with the room's, keeping the playing track.
  ///
  /// The room queue is data until the listener asks for it: another member
  /// changing the order must not silence what is playing right now.
  Future<bool> adoptRoomQueue() async {
    final List<Track> tracks = roomQueue;
    if (tracks.isEmpty) return false;
    final String? songId = _currentSongId;
    int index = songId == null
        ? 0
        : tracks.indexWhere(
            (Track track) => MusicId.tryParse(track.id)?.value == songId,
          );
    if (index < 0) index = 0;
    _applyingRemote = true;
    try {
      state.playQueue(tracks, startIndex: index);
    } finally {
      _applyingRemote = false;
    }
    queueInSync = true;
    _publishQueue(force: true);
    _notify();
    return true;
  }

  /// Accepts the forms the APK's invite share produces: a link with
  /// `roomId`/`inviterId` query parameters, `roomId|inviterId`, or two
  /// whitespace-separated values.
  static (String?, String?) parseInvite(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return (null, null);
    final Uri? uri = Uri.tryParse(text);
    if (uri != null && uri.queryParameters.isNotEmpty) {
      final String? room =
          uri.queryParameters['roomId'] ?? uri.queryParameters['roomid'];
      final String? inviter =
          uri.queryParameters['inviterId'] ?? uri.queryParameters['inviterid'];
      if (room != null && inviter != null) {
        return (room, inviter);
      }
    }
    final List<String> parts = text.split(RegExp(r'[|,\s]+'));
    if (parts.length >= 2) {
      return (parts.first.trim(), parts[1].trim());
    }
    return (null, null);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_beatInterval, (_) => _beat());
    _beat();
  }

  void _primePlayback() {
    _lastSongId = _currentSongId;
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
    if (_applyingRemote) {
      // The remote command already wrote this state; reporting it back would
      // make the two clients trade the same change forever.
      _primePlayback();
      return;
    }
    final String? songId = _currentSongId;
    if (songId == null || songId.isEmpty) return;
    final bool playing = state.playing;
    if (_lastSongId != songId) {
      final String former = _lastSongId ?? songId;
      _lastSongId = songId;
      _lastPlaying = playing;
      _lastPositionMs = state.position.inMilliseconds;
      _sendPlayCommand('PLAY', formerSongId: former, trigger: 'AUTO');
      _publishQueue();
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
    final String? songId = _currentSongId;
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
    String? formerSongId,
    int? progressMs,
    String trigger = 'MANUAL',
  }) {
    final String? id = roomId;
    final String songId = _currentSongId ?? '';
    if (!ready || id == null || songId.isEmpty || _owner.user == null) return;
    final int position = (progressMs ?? state.position.inMilliseconds).clamp(
      0,
      0x1FFFFFFFFFFFFF,
    );
    final Map<String, Object?> command = <String, Object?>{
      'clientSeq': ++_clientSeq,
      'commandType': type,
      'formerSongId': formerSongId ?? songId,
      'playStatus': state.playing ? 'PLAY' : 'PAUSE',
      'progress': position,
      'targetSongId': songId,
      'triggerType': trigger,
    };
    unawaited(
      _owner
          .listenTogether('command', {'roomId': id, 'command': command})
          .catchError((Object _) => <String, dynamic>{}),
    );
  }

  /// The room's clock.
  ///
  /// One beat reports presence, track, position and the queue version, and the
  /// answer carries the room's own state back. Overlapping beats are skipped:
  /// a slow service must not queue a second heartbeat behind the first.
  void _beat() {
    final String? id = roomId;
    if (!active || id == null || id.isEmpty || _disposed || _beating) return;
    _beating = true;
    final String songId = _currentSongId ?? '';
    unawaited(() async {
      try {
        final Map<String, dynamic> body = await _owner.listenTogether(
          'heartbeat',
          {
            'roomId': id,
            'songId': songId.isEmpty ? '0' : songId,
            'playStatus': state.playing ? 'PLAY' : 'PAUSE',
            'progress': state.position.inMilliseconds,
            'playlistVersion': _playlistVersion,
          },
        );
        if (_disposed || roomId != id) return;
        _applyRoom(body);
        // A beat that changed nothing must not rebuild the room sheet — the
        // sheet stays open while a room is active, and the answer is usually
        // identical to the last one.
        if (_changedByLastRoom) _notify();
      } catch (_) {
        // A missed beat is not a lost room; the next tick retries.
      } finally {
        _beating = false;
      }
    }());
  }

  /// Applies the room state one response carries.
  ///
  /// Everything here is optional: an older plugin answers a heartbeat with a
  /// bare `{code:200}`, and the room then simply keeps its current members and
  /// track instead of being torn down by a missing field.
  void _applyRoom(Map<String, dynamic> body) {
    final List<ListenTogetherMember> previousMembers = members;
    final List<Track> previousQueue = roomQueue;
    final bool previousInSync = queueInSync;
    final List<ListenTogetherMember> found = _membersOf(body);
    if (found.isNotEmpty) members = found;
    // A resumed room reports its id again; keep the local one authoritative.
    final String reportedRoom = '${body['roomId'] ?? ''}'.trim();
    if (reportedRoom.isNotEmpty && roomId == null) roomId = reportedRoom;

    _applyCommand(body['command']);
    _applyPlayback(body);

    final String version = '${body['playlistVersion'] ?? ''}'.trim();
    if (version.isNotEmpty && version != _roomVersion) {
      _roomVersion = version;
      if (version != _playlistVersion) _syncFromRoom();
    }
    final dynamic rows = body['playlist'];
    if (rows is List && rows.isNotEmpty) {
      roomQueue = _tracksOf(rows);
      queueInSync = _sameQueue(roomQueue);
    }
    _changedByLastRoom =
        !identical(previousMembers, members) ||
        !identical(previousQueue, roomQueue) ||
        previousInSync != queueInSync;
  }

  /// Applies a sequence-numbered play command from another member.
  void _applyCommand(Object? raw) {
    if (raw is! Map) return;
    final Map<String, dynamic> command = Map<String, dynamic>.from(raw);
    final String type = '${command['commandType'] ?? ''}'.toUpperCase();
    if (type.isEmpty) return;
    final int seq = (command['serverSeq'] as num?)?.toInt() ??
        (command['clientSeq'] as num?)?.toInt() ??
        0;
    final String user = '${command['userId'] ?? ''}'.trim();
    if (user.isNotEmpty && user == _ownUserId) return;
    // Without a sequence the command cannot be deduplicated; only a command
    // that names a different target is worth acting on.
    if (seq != 0 && seq <= _appliedSeq) return;
    if (seq != 0) _appliedSeq = seq;
    final int progress = (command['progress'] as num?)?.toInt() ?? 0;
    final String target = '${command['targetSongId'] ?? ''}'.trim();
    _applyingRemote = true;
    try {
      switch (type) {
        case 'PLAY':
        case 'GOTO':
          if (target.isNotEmpty && target != _currentSongId) {
            unawaited(_playRemote(target, progress));
          } else {
            if (!state.playing) state.play();
            if (progress > 0) unawaited(state.seekTo(_ms(progress)));
          }
          break;
        case 'PAUSE':
          if (state.playing) state.togglePlay();
          break;
        case 'PROGRESS':
          if (progress > 0 && (progress - state.position.inMilliseconds).abs() >
              2000) {
            unawaited(state.seekTo(_ms(progress)));
          }
          break;
        default:
          break;
      }
    } finally {
      _applyingRemote = false;
      _primePlayback();
    }
  }

  /// Applies the room's own playing track when the answer names one.
  ///
  /// A heartbeat answers with the room state even when no new command was
  /// reported (the other member reconnected, the room was resumed), so this is
  /// the path that keeps two listeners together without a command in flight.
  void _applyPlayback(Map<String, dynamic> body) {
    final String roomSong = '${body['songId'] ?? ''}'.trim();
    if (roomSong.isEmpty || roomSong == '0') return;
    if (roomSong == _lastSongId || roomSong == _currentSongId) {
      final String status = '${body['playStatus'] ?? ''}'.toUpperCase();
      final int progress = (body['progress'] as num?)?.toInt() ?? 0;
      if (status == 'PAUSE' && state.playing) {
        _applyingRemote = true;
        try {
          state.togglePlay();
        } finally {
          _applyingRemote = false;
          _primePlayback();
        }
      } else if (status == 'PLAY' && !state.playing) {
        _applyingRemote = true;
        try {
          state.play();
        } finally {
          _applyingRemote = false;
          _primePlayback();
        }
      } else if (_lastPlaying == true &&
          progress > 0 &&
          (progress - state.position.inMilliseconds).abs() > 8000) {
        // Two playing clients drift apart silently; a wide gap is a resync,
        // not a seek the listener made.
        unawaited(state.seekTo(_ms(progress)));
      }
      return;
    }
    final int progress = (body['progress'] as num?)?.toInt() ?? 0;
    unawaited(_playRemote(roomSong, progress));
  }

  /// Starts the track the room is playing, from the queue when it is there.
  Future<void> _playRemote(String remoteSongId, int progressMs) async {
    if (!ready) return;
    final int index = state.queue.indexWhere(
      (Track track) => _remoteValue(track) == remoteSongId,
    );
    _applyingRemote = true;
    try {
      if (index >= 0) {
        state.playTrackAt(index);
      } else {
        final MusicGateway owner = _owner;
        final MusicSong song = await owner.song(
          MusicId(
            provider: owner.provider.id,
            connection: owner.connectionId,
            kind: MusicEntityKind.song,
            value: remoteSongId,
          ),
        );
        state.playQueue(<Track>[state.catalog.trackFromMusicSong(song)]);
      }
      if (progressMs > 0) await state.seekTo(_ms(progressMs));
    } catch (_) {
      // A track the account may not play, or a room id that expired: the beat
      // after this one retries from whatever the room reports then.
    } finally {
      _applyingRemote = false;
      _primePlayback();
    }
  }

  /// Pulls the room queue after the version the service echoed changed.
  Future<void> _syncFromRoom() async {
    final String? id = roomId;
    if (id == null || id.isEmpty) return;
    try {
      final Map<String, dynamic> body = await _owner.listenTogether(
        'syncPlaylist',
        {'roomId': id},
      );
      final dynamic rows = body['playlist'];
      if (rows is! List || rows.isEmpty) return;
      roomQueue = _tracksOf(rows);
      queueInSync = _sameQueue(roomQueue);
      final String version = '${body['playlistVersion'] ?? ''}'.trim();
      if (version.isNotEmpty) {
        _roomVersion = version;
        _playlistVersion = version;
      }
      // A room that has a queue and a client that has none is not a conflict:
      // the client joined with nothing to play.
      if (state.queue.isEmpty && roomQueue.isNotEmpty) {
        await adoptRoomQueue();
      }
      _notify();
    } catch (_) {
      // The next beat reports the same mismatch and tries again.
    }
  }

  /// Republishes this client's queue so the other members see the change.
  ///
  /// Throttled: a queue is republished at most once every three seconds, and
  /// only when the serialized version actually changed.
  void _publishQueue({bool force = false}) {
    final String? id = roomId;
    if (!ready || id == null || id.isEmpty) return;
    final String version = _queueVersion();
    if (!force && version == _publishedVersion) return;
    final DateTime now = DateTime.now();
    if (!force && now.difference(_lastQueuePush) < const Duration(seconds: 3)) {
      return;
    }
    _lastQueuePush = now;
    _publishedVersion = version;
    _playlistVersion = version;
    unawaited(
      _owner
          .listenTogether('syncList', {
            'roomId': id,
            'playlistVersion': version,
            'playlist': [
              for (final Track track in state.queue.take(_maxQueue))
                <String, Object?>{
                  'id': _remoteValue(track),
                  'version': 0,
                },
            ],
          })
          .catchError((Object _) => <String, dynamic>{}),
    );
  }

  /// The queue reduced to the ids the service knows. Capped so a five hundred
  /// track queue does not turn the heartbeat into a payload.
  static const int _maxQueue = 200;

  String _queueVersion() {
    final List<String> ids = <String>[
      for (final Track track in state.queue.take(_maxQueue)) _remoteValue(track),
    ];
    return jsonEncode(ids);
  }

  List<String> _upcomingIds() {
    final List<String> ids = <String>[
      for (final Track track in state.queue.skip(1).take(40)) _remoteValue(track),
    ];
    return ids.where((String id) => id.isNotEmpty).toList();
  }

  bool _sameQueue(List<Track> other) {
    final List<Track> local = state.queue;
    if (local.length != other.length) return false;
    for (var index = 0; index < local.length; index++) {
      if (local[index].id != other[index].id) return false;
    }
    return true;
  }

  List<Track> _tracksOf(List<dynamic> rows) {
    final MusicGateway owner = _owner;
    final List<Track> tracks = <Track>[];
    for (final Object? row in rows) {
      if (row is! Map) continue;
      final String id = '${row['id'] ?? row['songId'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      tracks.add(
        Track(
          id: MusicId(
            provider: owner.provider.id,
            connection: owner.connectionId,
            kind: MusicEntityKind.song,
            value: id,
          ).cacheKey,
          title: '${row['name'] ?? row['title'] ?? ''}',
          artist: '${row['artist'] ?? ''}',
          album: '${row['album'] ?? ''}',
          duration: _ms((row['durationMs'] as num?)?.toInt() ?? 0),
          // The room only names the song, so the cover plate keeps the seed a
          // rebuilt row gets instead of inventing artwork the service never
          // sent.
          coverSeed: id.hashCode,
          coverUrl: row['coverUrl'] as String?,
        ),
      );
    }
    return tracks;
  }

  static Duration _ms(int value) => Duration(milliseconds: value < 0 ? 0 : value);

  static String _remoteValue(Track track) =>
      MusicId.tryParse(track.id)?.value ?? '';

  static Map<String, dynamic> _dataOf(Map<String, dynamic> body) {
    final dynamic data = body['data'];
    return data is Map<String, dynamic> ? data : body;
  }

  /// Reads the roster from a room response.
  ///
  /// Gateways name the list and its fields differently (`members`/`users`/
  /// `participants`, `userId`/`uid`, `nickname`/`userName`), and a plugin may
  /// answer with any of them; ids stay opaque strings either way.
  static List<ListenTogetherMember> _membersOf(Map<String, dynamic> body) {
    final Map<String, dynamic> data = _dataOf(body);
    final dynamic list = data['members'] ?? data['users'] ?? data['participants'];
    if (list is! List) return const <ListenTogetherMember>[];
    final List<ListenTogetherMember> members = <ListenTogetherMember>[];
    for (final item in list.whereType<Map<String, dynamic>>()) {
      final dynamic rawId = item['userId'] ?? item['uid'];
      if (rawId == null) continue;
      members.add(
        ListenTogetherMember(
          userId: rawId.toString(),
          name: '${item['name'] ?? item['nickname'] ?? item['userName'] ?? ''}',
          avatarUrl: (item['avatarUrl'] ?? item['avatar']) as String?,
        ),
      );
    }
    return members;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
