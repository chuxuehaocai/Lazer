import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../local/local_music_import.dart';
import '../local/local_music_page.dart' show runLocalImport;
import '../state/app_state.dart';
import '../widgets/plate_art.dart';
import '../widgets/accessible_controls.dart';

/// A compact touch surface for regular Android watches, square or round.
/// All playback, downloads and accounts use the existing Android application.
class WatchShell extends StatefulWidget {
  const WatchShell({super.key, required this.state, required this.round});
  final AppState state;
  final bool round;
  @override
  State<WatchShell> createState() => _WatchShellState();
}

class _WatchShellState extends State<WatchShell> {
  int _tab = 0;
  List<Track>? _openedTracks;
  String _title = '';
  final TextEditingController _query = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _captcha = TextEditingController();
  Timer? _smsTimer;
  int _smsSeconds = 0;
  String? _accountMessage;
  bool _loading = false;
  String? _error;
  int _request = 0;
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(state.localLibrary.load());
  }

  @override
  void dispose() {
    _request++;
    _query.dispose();
    _phone.dispose();
    _captcha.dispose();
    _smsTimer?.cancel();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final request = ++_request;
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await state.search(query.trim());
      if (!mounted || request != _request) return;
      setState(() {
        _openedTracks = result.tracks;
        _title = '搜索结果';
      });
    } catch (_) {
      if (mounted && request == _request) setState(() => _error = '搜索失败，请重试');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tracks = await state.catalog.playlistTracks(playlist.id);
      if (!mounted || request != _request) return;
      setState(() {
        _openedTracks = tracks;
        _title = playlist.name;
      });
    } catch (_) {
      if (mounted && request == _request) setState(() => _error = '歌单加载失败，请重试');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _sendCode() async {
    if (_loading || _smsSeconds > 0) return;
    setState(() {
      _loading = true;
      _accountMessage = null;
    });
    final result = await state.sendSmsCode(_phone.text.trim());
    if (!mounted) return;
    setState(() {
      _loading = false;
      _accountMessage = result.ok ? '验证码已发送' : result.error;
      if (result.ok) _smsSeconds = 60;
    });
    if (result.ok) {
      _smsTimer?.cancel();
      _smsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _smsSeconds <= 1) timer.cancel();
        if (mounted) setState(() => _smsSeconds = math.max(0, _smsSeconds - 1));
      });
    }
  }

  Future<void> _signIn() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _accountMessage = null;
    });
    final result = await state.signInWithPhoneCaptcha(
      _phone.text.trim(),
      _captcha.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _accountMessage = result.ok ? '登录成功' : result.error;
      if (result.ok) _captcha.clear();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([state, state.localLibrary]),
    builder: (context, _) => PopScope(
      canPop: _openedTracks == null && _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() {
            _request++;
            _loading = false;
            _openedTracks = null;
            _tab = 0;
          });
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final edge = widget.round ? constraints.maxWidth * .15 : 10.0;
              final vertical = widget.round ? constraints.maxHeight * .15 : 8.0;
              return ListView(
                key: ValueKey(
                  'watch-$_tab-${_openedTracks == null ? 'root' : _title}',
                ),
                padding: EdgeInsets.fromLTRB(
                  edge,
                  vertical,
                  edge,
                  vertical + 12,
                ),
                children: [
                  if (_openedTracks != null)
                    TextButton.icon(
                      onPressed: () => setState(() => _openedTracks = null),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('返回'),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final (index, icon, label) in const [
                        (0, Icons.play_circle_outline, '播放'),
                        (1, Icons.library_music_outlined, '音乐'),
                        (2, Icons.search, '搜索'),
                        (3, Icons.settings_outlined, '设置'),
                      ])
                        Expanded(
                          child: IconButton(
                            tooltip: label,
                            isSelected: _tab == index,
                            iconSize: 21,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 36,
                            ),
                            padding: EdgeInsets.zero,
                            icon: Icon(icon),
                            onPressed: () => setState(() {
                              _request++;
                              _loading = false;
                              _tab = index;
                              _openedTracks = null;
                              _error = null;
                            }),
                          ),
                        ),
                    ],
                  ),
                  if (_loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  if (_error != null)
                    Text(_error!, textAlign: TextAlign.center),
                  if (_openedTracks != null) ...[
                    Text(_title, textAlign: TextAlign.center),
                    ..._songs(_openedTracks!),
                  ] else if (_tab == 0)
                    ..._player(constraints.maxWidth - edge * 2)
                  else if (_tab == 1)
                    ..._library()
                  else if (_tab == 2) ...[
                    TextField(
                      controller: _query,
                      onSubmitted: _search,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: '歌曲 / 歌手',
                        isDense: true,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _search(_query.text),
                      child: const Text('搜索'),
                    ),
                  ] else
                    ..._settings(),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  List<Widget> _player(double width) {
    final track = state.current;
    final side = math.min(width * .32, 64.0);
    return [
      if (track != null) ...[
        const SizedBox(height: 6),
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox.square(
                dimension: side,
                child: PlateArt(
                  seed: track.coverSeed,
                  coverUrl: track.coverUrl,
                  size: side,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: IconButton(
                tooltip: '上一首',
                onPressed: state.previous,
                icon: const Icon(Icons.skip_previous),
              ),
            ),
            Expanded(
              child: IconButton(
                tooltip: state.playing ? '暂停' : '播放',
                onPressed: state.togglePlay,
                icon: Icon(
                  state.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                ),
              ),
            ),
            Expanded(
              child: IconButton(
                tooltip: '下一首',
                onPressed: state.next,
                icon: const Icon(Icons.skip_next),
              ),
            ),
          ],
        ),
        AccessibleSlider(
          semanticLabel: '播放进度',
          value: state.progress.clamp(0, 1),
          onChanged: state.seek,
        ),
        if (state.playbackError != null)
          Text(
            state.playbackError!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        if (state.lyrics.isNotEmpty)
          Text(
            state.lyrics
                .lastWhere(
                  (line) => line.time <= state.position,
                  orElse: () => state.lyrics.first,
                )
                .text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
      ] else
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('选择音乐开始播放', textAlign: TextAlign.center),
        ),
      ..._songs(state.queue),
    ];
  }

  List<Widget> _library() {
    final local = state.localLibrary.tracks
        .where((entry) => !entry.missing)
        .map((entry) => entry.track)
        .toList();
    return [
      _entry(
        '本地音乐 · ${local.length}',
        () => setState(() {
          _openedTracks = local;
          _title = '本地音乐';
        }),
      ),
      _entry(
        '最近播放',
        () => setState(() {
          _openedTracks = state.recentTracks;
          _title = '最近播放';
        }),
      ),
      if (state.home case final feed?) ...[
        _entry(
          '每日推荐',
          () => setState(() {
            _openedTracks = feed.daily;
            _title = '每日推荐';
          }),
        ),
        for (final playlist in feed.recommended)
          _entry(playlist.name, () => _openPlaylist(playlist)),
      ],
      for (final playlist in [
        ...state.collections.created,
        ...state.collections.subscribed,
      ])
        _entry(playlist.name, () => _openPlaylist(playlist)),
    ];
  }

  List<Widget> _songs(List<Track> tracks) => [
    if (tracks.isEmpty)
      const Padding(
        padding: EdgeInsets.all(12),
        child: Text('暂无歌曲', textAlign: TextAlign.center),
      ),
    for (var i = 0; i < tracks.length; i++)
      _entry(tracks[i].title, () {
        state.playQueue(tracks, startIndex: i);
        setState(() {
          _openedTracks = null;
          _tab = 0;
        });
      }, subtitle: tracks[i].artist),
  ];

  Widget _entry(String title, VoidCallback onTap, {String? subtitle}) =>
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 2),
        dense: true,
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
        onTap: onTap,
      );

  List<Widget> _settings() => [
    if (!state.signedIn) ...[
      const Text('账号登录', textAlign: TextAlign.center),
      TextField(
        key: const ValueKey('watch-login-phone'),
        controller: _phone,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(labelText: '手机号', isDense: true),
      ),
      TextButton(
        onPressed: _loading || _smsSeconds > 0 ? null : _sendCode,
        child: Text(_smsSeconds > 0 ? '$_smsSeconds 秒后重试' : '发送验证码'),
      ),
      TextField(
        key: const ValueKey('watch-login-captcha'),
        controller: _captcha,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _signIn(),
        decoration: const InputDecoration(labelText: '验证码', isDense: true),
      ),
      TextButton(onPressed: _loading ? null : _signIn, child: const Text('登录')),
    ] else ...[
      Text(state.user.name, textAlign: TextAlign.center),
      TextButton(
        onPressed: () => unawaited(state.signOut()),
        child: const Text('退出登录'),
      ),
    ],
    if (_accountMessage != null)
      Text(_accountMessage!, textAlign: TextAlign.center),
    _entry(
      '导入本地歌曲',
      () =>
          unawaited(runLocalImport(context, state, const LocalMusicImporter())),
    ),
    const Text('音量', textAlign: TextAlign.center),
    AccessibleSlider(
      semanticLabel: '音量',
      value: state.volume,
      onChanged: (v) => unawaited(state.setVolume(v)),
    ),
    _entry(
      state.themeMode == ThemeMode.dark ? '浅色外观' : '深色外观',
      () => unawaited(
        state.setThemeMode(
          state.themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
        ),
      ),
    ),
    const Text(
      '手表默认使用静态背景',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 11),
    ),
  ];
}
